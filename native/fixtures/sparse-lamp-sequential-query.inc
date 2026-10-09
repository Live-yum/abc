/* Test-only sequential query driver frozen from the v8 TerraWasm adaptation.
 * Source file SHA-256: 206316d613a60d309da1a05a8cfb538f3052a05dafe2e031719536f2fb259a3b
 * Retains the attribution and user-authorized source status recorded in
 * native/vendor/TerraWasm/SOURCE_MANIFEST.json; this is not a new license grant.
 * The differential runner substitutes this function in a temporary source
 * tree only. Production builds do not include this reference or a slow mode.
 */
int cx_query_step(CxWorld* w,uint32_t* work){
    while(*work&&w->x<w->query_x1){int status=cx_scan_step(w,work);if(status<0||w->event.kind)return status;if(status!=2)return TCW_CONTINUE;
        if(w->x>=w->query_x0){
            if(w->command.kind==TCW_VIEWPORT){
                if((w->x-w->query_x0)%w->query_stride==0){if(w->emit_y<w->query_y0)w->emit_y=w->query_y0;while(*work&&w->emit_y<w->query_y1){if(w->result_count>=w->result_capacity)return TCW_INVALID;pack_cell(w,w->x,w->emit_y,w->result+w->result_count*4u);++w->result_count;w->emit_y+=w->query_stride;--*work;}if(w->emit_y<w->query_y1)return TCW_CONTINUE;}
            }else{
                while(w->point_index<w->point_count&&w->points[w->point_index].x<w->x)++w->point_index;
                while(*work&&w->point_index<w->point_count&&w->points[w->point_index].x==w->x){if(!bind_point(w,w->points[w->point_index].y))return TCW_MEMORY;++w->point_index;--*work;}
                if(w->point_index<w->point_count&&w->points[w->point_index].x==w->x)return TCW_CONTINUE;
            }
        }
        ++w->x;w->y=0;w->col_stage=0;w->emit_y=0;
    }
    if(w->x<w->query_x1)return TCW_CONTINUE;return cx_command_complete(w);
}
