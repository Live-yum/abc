/* Original bounded timer ordering adapter. Behavioral reference only:
 * Wiring.cs 525-646, 837-979, 1012-1016 and 160-208 at
 * 8255d34616c780af12079425ac92a0a7aed87d71. No decompiled implementation copied.
 *
 * Only timer-bearing ordinary-wire networks are retained. Routing tiles make
 * their own networks ineligible for this index; ambiguous commands then fail
 * transactionally. An optional index must not prevent loading, inspection,
 * saving, or unambiguous single-timer operation when its budget is exhausted.
 */
#include "terra_circuit_world_internal.h"
#include <stdlib.h>
#include <string.h>

#define ORDER_CELLS 65536u
#define ORDER_CACHES 16u
#define ORDER_CACHED_HITS 4096u
#define ORDER_VIRTUAL 0x80000000u

typedef struct OrderNet { uint32_t id, unsupported; } OrderNet;
typedef struct OrderCell { uint32_t x,y,net,target; } OrderCell;
typedef struct OrderGate { uint32_t id,x,y,mask; } OrderGate;
typedef struct OrderCache {
    uint32_t x,y,width,height,mask,count,valid;
    uint64_t stamp;
    uint32_t* hits;
} OrderCache;
struct CxTimerOrder {
    OrderNet* nets; uint32_t net_count;
    OrderCell* cells; uint32_t count,capacity;
    OrderGate* gates; uint32_t gate_count,gate_capacity;
    uint32_t* queue; uint8_t* seen;
    uint32_t head,tail,queue_capacity,stage,colour,seed_cursor;
    uint32_t x,y,width,height,mask,gate_mask;
    uint32_t cache_slot,cache_cursor,building;
    uint64_t clock;
    OrderCache cache[ORDER_CACHES];
};
static const int order_dx[4]={0,0,1,-1},order_dy[4]={1,-1,0,0};
static int net_compare(const void* a,const void* b){uint32_t x=((const OrderNet*)a)->id,y=((const OrderNet*)b)->id;return x<y?-1:x>y;}
static int cell_compare(const void* a,const void* b){const OrderCell* x=a;const OrderCell* y=b;if(x->x!=y->x)return x->x<y->x?-1:1;if(x->y!=y->y)return x->y<y->y?-1:1;uint32_t c=x->target&3u,d=y->target&3u;return c<d?-1:c>d;}
static OrderNet* order_net(CxTimerOrder* o,uint32_t id){if(!o||!id)return NULL;uint32_t lo=0,hi=o->net_count;while(lo<hi){uint32_t m=lo+(hi-lo)/2u;if(o->nets[m].id<id)lo=m+1u;else hi=m;}return lo<o->net_count&&o->nets[lo].id==id?o->nets+lo:NULL;}
static uint32_t order_cell(CxTimerOrder* o,uint32_t x,uint32_t y,uint32_t colour){uint32_t lo=0,hi=o->count;while(lo<hi){uint32_t m=lo+(hi-lo)/2u;OrderCell* p=o->cells+m;if(p->x<x||(p->x==x&&(p->y<y||(p->y==y&&(p->target&3u)<colour))))lo=m+1u;else hi=m;}return lo<o->count&&o->cells[lo].x==x&&o->cells[lo].y==y&&(o->cells[lo].target&3u)==colour?lo:CX_NONE;}
void cx_timer_order_free(CxWorld* w){
    CxTimerOrder* o=w->timer_order;if(!o)return;w->timer_order=NULL;
    cx_free(w,o->nets);cx_free(w,o->cells);cx_free(w,o->gates);cx_free(w,o->queue);cx_free(w,o->seen);
    for(uint32_t i=0;i<ORDER_CACHES;i++)cx_free(w,o->cache[i].hits);cx_free(w,o);
}
static int order_grow(CxWorld* w,void** data,uint32_t* capacity,uint32_t needed,uint32_t size){
    if(needed<=*capacity)return 1;uint32_t next=*capacity?*capacity*2u:64u;
    if(next>ORDER_CELLS)next=ORDER_CELLS;if(needed>next)return 0;
    void* p=cx_optional_alloc(w,next*size);if(!p)return 0;
    if(*data)memcpy(p,*data,*capacity*size);cx_free(w,*data);*data=p;*capacity=next;return 1;
}
void cx_timer_order_prepare(CxWorld* w){
    uint32_t timers=0,nets=0;
    for(uint32_t i=0;i<w->device_count;i++){CxDevice* d=w->devices+i;if(d->tile.type!=144u)continue;uint32_t n=0;for(uint32_t c=0;c<4;c++)n+=d->nets[c]!=0;timers+=n!=0;if(nets>ORDER_CELLS-n)return;nets+=n;}
    if(timers<2u)return;
    CxTimerOrder* o=cx_optional_alloc(w,sizeof(*o));if(!o)return;memset(o,0,sizeof(*o));w->timer_order=o;
    o->nets=cx_optional_alloc(w,nets*sizeof(OrderNet));if(!o->nets){cx_timer_order_free(w);return;}
    for(uint32_t i=0;i<w->device_count;i++){CxDevice* d=w->devices+i;if(d->tile.type!=144u)continue;for(uint32_t c=0;c<4;c++)if(d->nets[c])o->nets[o->net_count++]=(OrderNet){d->nets[c],0};}
    qsort(o->nets,o->net_count,sizeof(OrderNet),net_compare);uint32_t n=0;
    for(uint32_t i=0;i<o->net_count;i++)if(!n||o->nets[i].id!=o->nets[n-1u].id)o->nets[n++]=o->nets[i];o->net_count=n;
}
void cx_timer_order_cell(CxWorld* w,uint32_t y,uint32_t colour,uint32_t right,uint32_t down,uint32_t left,uint32_t up){
    CxTimerOrder* o=w->timer_order;if(!o)return;OrderNet* a=order_net(o,right);OrderNet* b=order_net(o,down);
    const TxTile* tile=w->column+y;
    /* Special routing also matters on inactive tiles in the pinned source.
     * Do not replace its repeated direction queue with an ordinary visited set. */
    if(tile->type==424u||tile->type==445u){if(a)a->unsupported=1;if(b)b->unsupported=1;OrderNet* l=order_net(o,left);OrderNet* u=order_net(o,up);if(l)l->unsupported=1;if(u)u->unsupported=1;return;}
    if(!a&&!b)return;
    if(!order_grow(w,(void**)&o->cells,&o->capacity,o->count+1u,sizeof(OrderCell))){cx_timer_order_free(w);return;}
    CxDevice* device=cx_device_find(w,w->x,y);uint32_t target=device&&device->tile.type==144u?(uint32_t)(device-w->devices)+1u:0;
    if(target>=ORDER_VIRTUAL/4u){cx_timer_order_free(w);return;}
    o->cells[o->count++]=(OrderCell){w->x,y,right,target*4u+colour};
}
void cx_timer_order_gates(CxWorld* w){
    CxTimerOrder* o=w->timer_order;if(!o)return;
    const uint32_t* rows=w->compile_rows+w->height*4u;
    for(uint32_t i=0;i<w->compile_gate_count;i++){
        uint32_t y=rows[i],mask=cx_wire_mask(w->column+y),target=0;
        for(uint32_t c=0;c<4;c++){uint32_t row=y;if(y+2u==w->height&&y)row=y-1u;if((mask&(1u<<c))&&order_net(o,w->ids[row*4u+c]))target=1;}
        if(!target)continue;
        if(!order_grow(w,(void**)&o->gates,&o->gate_capacity,o->gate_count+1u,sizeof(OrderGate))){cx_timer_order_free(w);return;}
        o->gates[o->gate_count++]=(OrderGate){w->gate_at_y[y],w->x,y,mask};
    }
}
void cx_timer_order_finish(CxWorld* w){CxTimerOrder* o=w->timer_order;if(o&&o->count)qsort(o->cells,o->count,sizeof(OrderCell),cell_compare);}
void cx_timer_order_reset(CxWorld* w){CxTimerOrder* o=w->timer_order;if(!o)return;for(uint32_t i=0;i<ORDER_CACHES;i++){cx_free(w,o->cache[i].hits);memset(o->cache+i,0,sizeof(OrderCache));}o->stage=o->building=0;o->clock=0;}
void cx_timer_order_begin(CxWorld* w){
    w->timer_hit_count=w->timer_hit_colours=w->timer_order_unsupported=w->timer_hit_events=0;
    CxTimerOrder* o=w->timer_order;if(o){if(o->building)o->cache[o->cache_slot].valid=0;o->stage=o->building=0;}
}
void cx_timer_order_hit(CxWorld* w,CxDevice* d,uint32_t colour,uint32_t net){
    if(w->optimization&&d->wire_hit_epoch!=w->wire_trip_epoch){d->wire_hit_epoch=w->wire_trip_epoch;d->wire_hit_mask=0;}
    uint32_t bit=1u<<colour;if(d->wire_hit_mask&bit)return;
    if(!d->wire_hit_mask){++w->timer_hit_count;w->timer_first=(uint32_t)(d-w->devices);}
    d->wire_hit_mask|=bit;w->timer_hit_colours|=bit;++w->timer_hit_events;
    OrderNet* n=order_net(w->timer_order,net);if(n&&n->unsupported)w->timer_order_unsupported=1;
}
static int order_fail(CxWorld* w,const char* message){return cx_fail(w,TCW_UNSUPPORTED,message);}
static int order_enqueue(CxWorld* w,CxTimerOrder* o,uint32_t value){if(o->tail>=o->queue_capacity)return order_fail(w,"timer FIFO queue exceeds the bounded index");o->queue[o->tail++]=value;return 0;}
static int order_apply(CxWorld* w,CxTimerOrder* o,uint32_t id,uint32_t colour){
    if(id>=w->device_count)return order_fail(w,"timer FIFO cache has an invalid target");CxDevice* d=w->devices+id;uint32_t bit=1u<<colour;
    if(!(d->wire_hit_mask&bit))return order_fail(w,"timer FIFO trace disagrees with the compiled pulse");
    if(cx_toggle_timer(w,d)<0)return -1;d->wire_hit_mask&=~bit;--w->timer_hit_events;
    if(o->building){OrderCache* c=o->cache+o->cache_slot;if(c->hits&&c->count<ORDER_CACHED_HITS)c->hits[c->count++]=id*4u+colour;else{o->building=0;c->valid=0;}}
    return 0;
}
static int order_start(CxWorld* w,CxTimerOrder* o){
    o->x=w->seed_x;o->y=w->seed_y;o->width=w->seed_width;o->height=w->seed_height;o->gate_mask=0;
    if(w->vm_source_gate){uint32_t lo=0,hi=o->gate_count;while(lo<hi){uint32_t m=lo+(hi-lo)/2u;if(o->gates[m].id<w->vm_source_gate)lo=m+1u;else hi=m;}if(lo==o->gate_count||o->gates[lo].id!=w->vm_source_gate)return order_fail(w,"timer FIFO gate origin is not represented");OrderGate* g=o->gates+lo;o->x=g->x;o->y=g->y;o->width=o->height=1;o->gate_mask=g->mask;}
    if(!o->width||!o->height||(uint64_t)o->width*o->height>=ORDER_VIRTUAL)return order_fail(w,"timer FIFO seed rectangle exceeds the bounded index");
    o->mask=w->timer_hit_colours;
    for(uint32_t i=0;i<ORDER_CACHES;i++){OrderCache* c=o->cache+i;if(c->valid&&c->x==o->x&&c->y==o->y&&c->width==o->width&&c->height==o->height&&c->mask==o->mask){c->stamp=++o->clock;o->cache_slot=i;o->cache_cursor=0;o->stage=4;return 1;}}
    if(!o->queue){o->queue_capacity=o->count*5u+4u;o->queue=cx_optional_alloc(w,o->queue_capacity*4u);o->seen=cx_optional_alloc(w,o->count?o->count:1u);if(!o->queue||!o->seen){cx_free(w,o->queue);cx_free(w,o->seen);o->queue=NULL;o->seen=NULL;return order_fail(w,"timer FIFO workspace does not fit the available memory budget");}}
    o->cache_slot=0;for(uint32_t i=1;i<ORDER_CACHES;i++)if(o->cache[i].stamp<o->cache[o->cache_slot].stamp)o->cache_slot=i;
    OrderCache* c=o->cache+o->cache_slot;c->stamp=++o->clock;
    c->valid=0;c->x=o->x;c->y=o->y;c->width=o->width;c->height=o->height;c->mask=o->mask;c->count=0;
    if(!c->hits)c->hits=cx_optional_alloc(w,ORDER_CACHED_HITS*4u);o->building=c->hits!=NULL;
    o->colour=0;o->stage=3;return 1;
}
int cx_timer_order_step(CxWorld* w){
    if(!w->timer_hit_count)return 0;
    if(w->timer_hit_count==1u){CxDevice* d=w->devices+w->timer_first;for(uint32_t c=0;c<4;c++)if(d->wire_hit_mask&(1u<<c))if(cx_toggle_timer(w,d)<0)return -1;d->wire_hit_mask=0;w->timer_hit_count=w->timer_hit_events=0;return 0;}
    if(w->timer_order_unsupported)return order_fail(w,"multiple timers on a junction or PixelBox network require directional FIFO traversal");
    CxTimerOrder* o=w->timer_order;if(!o)return order_fail(w,"multiple-timer FIFO index is unavailable (65536 wire-colour cells or memory budget exceeded)");
    if(!o->stage)return order_start(w,o);
    if(o->stage==4){OrderCache* c=o->cache+o->cache_slot;if(o->cache_cursor<c->count){uint32_t hit=c->hits[o->cache_cursor++];int s=order_apply(w,o,hit/4u,hit&3u);return s?s:1;}if(w->timer_hit_events)return order_fail(w,"timer FIFO cached trace is incomplete");w->timer_hit_count=0;o->stage=0;return 0;}
    if(o->stage==3){
        while(o->colour<4u&&!(o->mask&(1u<<o->colour)))++o->colour;
        if(o->colour==4u){if(w->timer_hit_events)return order_fail(w,"timer FIFO trace is incomplete for this source topology");if(o->building)o->cache[o->cache_slot].valid=1;o->building=0;o->stage=0;w->timer_hit_count=0;return 0;}
        memset(o->seen,0,o->count);o->head=o->tail=o->seed_cursor=0;o->stage=1;return 1;
    }
    if(o->stage==1){
        uint32_t area=o->width*o->height;if(o->seed_cursor==area){o->stage=2;return 1;}
        uint32_t ordinal=o->seed_cursor++,x=o->x+ordinal/o->height,y=o->y+ordinal%o->height;
        uint32_t cell=order_cell(o,x,y,o->colour);
        if(cell!=CX_NONE){o->seen[cell]=1;return order_enqueue(w,o,cell)?-1:1;}
        if(cx_inside_wiring(w,x,y))return 1;
        uint32_t mask=w->vm_source_gate?o->gate_mask:cx_bound_wire_mask(w,x,y);if(!(mask&(1u<<o->colour)))return 1;
        if(mask&256u)return order_fail(w,"multiple timers reached from a routing-tile border seed require directional FIFO traversal");
        for(uint32_t d=0;d<4u;d++){int64_t nx=(int64_t)x+order_dx[d],ny=(int64_t)y+order_dy[d];if(nx<0||ny<0||!cx_inside_wiring(w,(uint32_t)nx,(uint32_t)ny))continue;if(order_cell(o,(uint32_t)nx,(uint32_t)ny,o->colour)!=CX_NONE)return order_enqueue(w,o,ORDER_VIRTUAL|ordinal)?-1:1;}
        return 1;
    }
    if(o->head==o->tail){++o->colour;o->stage=3;return 1;}
    uint32_t item=o->queue[o->head++],x,y;
    if(item&ORDER_VIRTUAL){uint32_t ordinal=item&~ORDER_VIRTUAL;x=o->x+ordinal/o->height;y=o->y+ordinal%o->height;}
    else{OrderCell* cell=o->cells+item;x=cell->x;y=cell->y;uint32_t target=cell->target/4u;
        if(target&&!(x>=o->x&&x-o->x<o->width&&y>=o->y&&y-o->y<o->height)){CxDevice* d=w->devices+target-1u;if(d->wire_hit_mask&(1u<<o->colour)){int s=order_apply(w,o,target-1u,o->colour);if(s)return s;}}
    }
    for(uint32_t d=0;d<4u;d++){int64_t nx=(int64_t)x+order_dx[d],ny=(int64_t)y+order_dy[d];if(nx<0||ny<0||!cx_inside_wiring(w,(uint32_t)nx,(uint32_t)ny))continue;uint32_t next=order_cell(o,(uint32_t)nx,(uint32_t)ny,o->colour);if(next!=CX_NONE&&!o->seen[next]){o->seen[next]=1;int s=order_enqueue(w,o,next);if(s)return s;}}
    return 1;
}
