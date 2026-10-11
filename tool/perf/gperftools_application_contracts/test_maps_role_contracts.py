"""Offline maps-role regressions; no SDK, profiler, ELF inputs or target run.

The compressed fixture contains every original startup.maps byte from run
38161356734 (698563d); it contains no ELF payloads. No q0/q7 snapshot or sampled
PC exists for that failed run. All profile views, PCs, deleted mappings and
mutations below are explicitly synthetic tests, not its missing failure line.
"""
from __future__ import annotations

import base64
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest
import zlib

import application_contract as a

STARTUP_SHA256 = '28e8b366af03c20dba0a67285a9f72bd9397e22acc8de87c27816851d0514c40'
STARTUP_BYTES = 80921
# Complete 786-line startup byte evidence, zlib + Base85. No external input.
STARTUP_Z85 = (
    'c-qaKU2o(zvWD;dD{{ZEEq;g}dwmwU$+=o!F~DMBP$cE)#P0U#ZcjY<^+&cS^~)Yp^eSXKUd+tOVd*JJWU*K*lC7Y|_No(2(_FXV'
    'LJb!`?XRz&erm$cPmTI}Lw?enNlMvI@BG|;-97r-{quI~_qV_A_P^bl&c6NWo;MHf_F=Pqez|=S{Pt<T>o*U6`2E%m{~Y~(Z~EQ-'
    '-d`bqRz{D?yo}1wiz}m1856x3c5!74D${+kG94;o-<0`1D8nzROwW2b)tRnoiE1Kc#tPj0{q^skl0X0c>dn)Cu4LbEN&TD9^>jg!'
    '4T3U47+>>n_fLM`A9uTl!?k&Ode~TV-0Zg3gTUeTa5VO}YjZsAH{J8=uZLIB4Wf7d_q_4PJNNwfbaU8Up?b5fJZdlGucj+UUEAor'
    '^1qs{E$S-%+PVtVRYvu{{j2FJXI%%QCDU#7DwMIO55Y*NG)n@ci3Hxh-1YUM!0Gid8b0+Bfkp!S0|Fcb*jVH}gEFYjS@XWNd_L@N'
    '4`0pR-}bxh@o;<GKl|hNCx7ewujbqH?f(q_{OkFjW_!3f9{Vd~P2hEw(QJ3yzdN%(UW1JsZq~z{`#$>)#xg;Gk3|+g3kThK5LhDc'
    'NI)=C>|wd!cxRPYWh@f}`p|<EQKct%XOUNBEHerG*(&hIZtG`NqK7oD;6rw&JGV{#(}yxafUt6^w1nfG^PfJH2?De!*W`wq`T5Se'
    '?|n{{P-YhBb4@Ok83jy}Z`7eo5Fq(R9m)g&n*Xw)Oc3A&8})Fr4)1Iiyu3!p_G7)~-O)cj-9Gxq-TwRa?)TyM1M^|%Jf}W!J9M1i'
    '{N3Asx*L9H=dLm6Fe~I1T)9gr<WM0Wy&?K33VBqh{|hJt^?&SuPPLPLhC&>hOWs_CGC{x<?5T#EF}Sl}Syjd|lYpGOq{DfGWI_&o'
    'gnIX7elz=9YwXw2OR~Fdzq!A4t<uATDnXf6-l@hgCmJDo-nYYF_WHpKe)A@Ft*?+jDf59B>7o}|us1XgdPCzsU^8+2It-5ss?uWv'
    '?9UqDd#d!<K>E-?CY$!I09N3>E$6O;n@xBAz!ydTrfUlJ<Q=*zUGr{$AyOrjnFVO>HHI>?K)2MES}H%@mb#vGQVxT%mRT;S6s>AS'
    'LtCQ<*VKCPPFo86Ng3AV-h3!C3Gl91B?vd0?%aMrl{ONvIS(h42?C_GSpta#T$V7F2?DfrSpo$C+fw@HUT28L?ZYb#Hw<@IM*g|G'
    'A2*NwVKaZQaKriTD))9mnIND?fu*+-%1i>?2L!rEKxb7N%Zvgp2rLoYnSjX=LYYy(2Z1Gmj|7bJ%Q649X#Cchqq*JKXLo$K8UFtj'
    'Dlu!69jt^hLBOi)U?r591ax+=63PStud_WyC^HK5yj`A25oM#|gCF?jA3mLeZ9#>gkCp_wjn=Bm>ock_>%;$?sj$1prvd1$H;?9i'
    'G8o~uGXvv=#`Dj3<~bax8n1Hk%c;yP;F6W76_mgKlHP)augbhAaVPloo5I)k+vnF`{`|{7{`rj#3f|Bga?@NPXrk)a!%)?znj)1)'
    '&+6(?Ia1@;eqWC&kQ()qgw&%-q^d<nkToB71e?w=XB*wB-V7c<Yla`?yN)nVm89K|j^M<fmGR47ss6Y!Y-nkUaMx=?`(dQrIqI}9'
    'w9}Re-<tQ8@u&=rWj?`BOe#$JnC8><F%9ZNKDRTQRG9UlnL*Q3W)@(XLDN(w2=v*A#Z+b%;8~T%GP6LNRcS0U3J{u|{hG?m0wSjp'
    'fyu1b3z<_Xl$iv$%&WvB0hL#YD-_UqmAD20q4O$<NWkP(5(Wjjyh@@&0s8@hMFIB#!l}n5jJxbZk7Z^7pH*orGYj-tmBunbptXHg'
    'rLoK;;F_#TW0_fiWK|l=OaeX0tJFsVG_O)mQGn%D>Q7dK2$D53q0B6hH8Y{iERZ!bq0B5GK0pvCAU{BmD3BY+Ph~~{8U&W!5{(38'
    'I~jq)d-FN+1O3(LF5Eu)gSk6=HO}wv#@}qV&c9qCXNKlR>Qk9ffCYi2$6{v!U5*gSi~?L{LtImtSs)kUn#zm<t;~kFrZTfYF2psJ'
    '83lyQhPb9Ovw+VLLYYxO27x7lJQK*pC#Eu^fC>Uj1QiR2Tzq0GGYV*#%>|gs%mO4w2xUeA69kqBCK6CQFEEyw1+wNgl$iyx<~EcG'
    '0>)&`Z74GfWX)|TGYe$RZ74Gd_%^SSj|4<sB`;7w=2h|%1=I%!Cv)3Tm9@{I%q)-#n@(j$0UHFC2sRR6)?A_o2%H(3wa=l<DByy?'
    '(qp+ZfvkNFWkvxX1eOT?OdxBYLzz*a4+2Ys{!AcipF^290o??F1;SKj7RcG>smv%qSk_sc%1i<-XP>7sqW}#8O9Xl*kh9NInNffR'
    'fh7Vv6QDUlC^HK1Ah1N>u|WR;fj$!8sW`*n+O%p#T<pGkd<}|`n<fOsCd!NysYM1wkphu2l}}t0DG{kIf>emqsZ8XeNPR-`COzlU'
    'wo0r({^RFg?p}L<S8fB`5jAmHoY~M<<gy01JPOM(S&@5k)Lt*5X$fAH>yR6D1TCw{^}ub(LcP*-9e1qC<b-VT6}NGaiB&>&i1g_R'
    'n1aaY#YQ<qq}Ge=0T~aJ;;EN%$kR|uxA{cZsmv^ptZ#y<)b!}0j;|B$=J;04CBLCp2%4!hm2+B}dg}5;-zF1Fi&6t<rb5Ldu66aO'
    'Jy5ak4OCx^3e`{MGw7!>lYmeQ)vsNt=Ch5J44A+qamZV!I!tnknhzI|9~LyIzywE3(gtT6f(GT8BW7meC^KkKgV`a|Wh>oSW)|?7'
    'D8*D}5+FWLASl3-$rOscKi!;r4KI%mVai?K5PpT60A*biqN05z=*XF%Jua>!x~&E6TZEz^Cr(s@dW7P@ow#bR_q5Vw%rMH;JXnpU'
    '2Wza}soP;FM73O@<uAYd>wn+0Y;MREQf4GX*c8Pao}$Rp=&QFHDnK=)J>_i-7amq$Dy3Z=<SCk}d#AEyCzP25a(VJonMpwB^5my7'
    'K_I^<U@9{S*nTO@Le>n;&BMdy`SF^zL&H(m&2#s>Jw7)#l;1S`hEI7M6Z=gOLxhi9PTOBhk%>JjLInknn<!5&r$}H2MI;BGgepod'
    'sE9meY77^cM?p1?@#`yc%Fi%Vv)r7`RAv^)&Dl(4W`W$C%~WO<5Fa225HKSD3<d={o_4{RTGOu`H`{*qYT3jMze37{wDB~NuY<Hu'
    '$Fz$!fuN)g(&49bIzm=@N{1ELMbrF@Rzey?+O&bEa!u^@$!?6b{%{y0WrT$8ae_@`PtxJ^;$%;d%%W$Ob;)ROeB4-7T{5=Wv&my!'
    'myGSmCkIo4uM1^(w>gfEcXK1@6><X9G&Yr(UKBcVCMb!bAyn3ao)VZ|FQTMG#;QRLLZjJe)>ead2<@|7<5*@Apmf2urNSADTDtw?'
    '-DZ3A4<U>@I4I2((k3)hsi1rfG{XuJPxTO87tINxX{wj5g2orlBj1nG%4mjYk@mp&s>p(W=&uKhs+*IiYdAQ4rnRZ+RT9~vaT86d'
    'T9rhe!qKl6aZR?BkXVC7l!riEB_!5d(Wa`8<n1b3`dV|%qq~24ey8e+7TL+U!#Zp<=OXqCbZs`e2O^$IGPT(r*>N}4)n;RlD4T_F'
    '4qsy>Uk+a%d%v|l&bOFYGnk}i3@d=KK}(vNG^_x|W-ZwT!Pp(0Eth3g!5qPIp>i>{25h_Q!}qQIkt>mF(!N${E;_+7-da`E<f7q}'
    'Ha&bT%|#DD#uIg_CKrvhT1xd>wFLH+yEj|64@1`zSYd@$@rp886|4~)e_>k{jGy>y6?tD39DU<xu7uS6#@HL{WREDAqHB8NgWn!@'
    '`?sh_i*;IKf2d_D_*EQ>rc!q)pQ|_)Eta;ae6iwKtj#($SiT|_>#|vLvY1|3mtXqLi$BEKhZAfjv!$M}G#Q-^(=PRerO7yiF=DAV'
    'EKSBi_}LalsxBFuu~7>(jL4Pbr@bHQ_wh$GMwg6UaOBIQu~#%^!J{sZMpw^t7e%A(G<LzAFONq1Y5Y<(BP-EvzhOW0$p-u6u31=U'
    'QI^}G`RvHT(ucxa9HVyha$Fpuc5GqYMPV*>7TuCVuh($Dy!1+Zd;DP>fz#HelMAM+EEbJ*x3r+9EEWxQr!R&@BYn1~Tw4)~2Kwxn'
    'lekJXYl0qM2)Q1r^N(0G&YfMTQf0Adm^-)79hJqRW83+QVWaM#U+4kLVlh@~%|exuYdhZihnF8ZU5ho@#Xfvj59`n-yU0orUJ;8{'
    '%9-?JWnpaelB4-+Qu8IFx$w!6;m~1-m7)KzlN-kTJ$f}hwoz?0C|amKo-HJ`pglfmAI}$7d(s}Aw|M0;5!ImRx%F<zgIZI6fBxmm'
    'JIfm<RN!{hEEuPv+z~Z#S>((xRgudya&2n)YI&|jZWOuVrY0A^FZ0<Hn~p)>+;Nhwh%II76#YR*Ofu=xxeq0gnETM3Ek5;?kl=lE'
    'ak>Sq^kOmHqKmifiL-YKBJo>FlCN(#o!fN_DP8TVA?we-xXt0o9PQU1RK>w^*GDthoKz)a4`Z8XxU8x^vu$9+Y-v;pHLFUd4U(gZ'
    'VfwmceA`rKtK?W_5)gLD1nO0)jw2I!Qc-|8vMREGoK+#>yr7MzG(;UDPG#6Q_9$f?qDNvh%v5b1BG`D_HTkNB0ZQAE?D7+fkwx3l'
    '?D7+fR?c?p0|bTw`~w8EDP8*kLW=_80|bEr@&g2k0_p<<g#!8m1hf&I`2fM7K=%PchXVEk1ZdKZ+HB<;%gh3~?Y^cmqW}v6O9U1R'
    'hz|&eNFcXA*i>c|;6Y%Cz|RD7`-4qoMuFCeY?6A50-~Y0tv#nQvp{lIMi99wMfLva{@U;NyO1iu_++mFY$Egc)L>qf%sG;y@h&lS'
    '$qvcU+or58IeObsO`?_GHde{>CPstnwJJmP(Vfi*1;|V^sTseLL~KQEY%jYyM2ke1O6n>}#JYR7Tdk`@#5yZzy5=;i7BK#CIJ(h`'
    'YH!*r!~`a3bjm7~WRlYc2E#?X^R?+JF;AOkzg|S?wVkZRl*o*>Ywc7mrb1@ELnN>mZMaAVL)%8L+O+234?gOsr&Y6oG9lB;yGkM%'
    'z7}RuF{q+Qe6g%c#h{8JJ4D)445}y+>@wlqLiJhK&)WU>r(@U~gx|0$Bn2$x$(<kzW9jLn%;6$RS|^dUER2=-v<d?VgjIZ6g-@$+'
    'Ed=2epB56wU$@H2nlO4gz3cTNy^k7EY>l4QJdKk`LR=waCi>(G!h%Hb4d_{>wXQ<c`1LhO`FJIX1c~uB#<mWTB5`5ysa)mbb%)8x'
    'qtlB1fSH(vCdYv#nFgOTPB135p3`8fj8lsVt;LMqZG7GvtHqSaRC#k{(0CY~%wu45RW<MSyW_*g?j9d^+jxuA2{*G%D&?vU8yq5P'
    'bt(a>3ftmy$LUD4_H*0lxx3Wj`Z{d%9I}T7Ol2m4v)x_LpIf=U_VE31^wZFnsgt6xw~JshvWl1pQku(Pp{Zc;+>B`}a$$yMxQP5_'
    'M{9CB<VHgT=W22-a`P2&EHeqD)0~IFGg;MY9)8=n^X9@}dPOj&Qfn5=LLrM!FdsQuw5tV$U7UssncDcKFjOKm>MEJ828~{CG80u&'
    '&DTJ`xJUamZVT1`)F9NRLb8RS*v7n1C9M~RdW6P%T(;Gq5MyV3JohVVL3=dWJz1zos}@9lG0#6Dv6Y^kb4V&7u_Hb^8irLuqSfu&'
    'iy&J>#v4WQN=Si7x#0Hm^=_c^_6Gylqt)&E1)sk(7+NWBXmXF5(qP_D1hZ7=q5_y9n5QBb6~G+9A{~ZZH{IF&L8lcS{0b=(lJMlL'
    'V?iXrr;I0#NTsJF(NoG)Dt=L<L}cV8ky<ZSAu>N}#BtV$lVsYS)ReDDv3BOT--JDKPE+e6Xrj{O($>OM$fg`FNNRO{X(~Y~y%ZHK'
    'Cyf`i%6e2Zo3u}dVb@KRy6*XKO<t+&hS5{4r`SKWamQ%uVOzw;+laA>Sc%nGM%9?t#9}>`QBa?|idd}3ilz-z!`I}an&aVVGi5(d'
    'q2Q4-L3NaONUA|$dl<pv?JTIS1;rRPkHc3?RD(uOYE$8Z!cgpUy5y=uqU0)<&c8gF<20*2LpyA%wolCwm4#ZgOHQVe^~ypWIy-0k'
    '#CO%88ljQ9LtQl}x=haIeJqDH&-Dwb6{{@g!yk`k+<l49=|dwXFx!SKq~;W3whcjM<V(`F7Skd#%6ei=Ev7?elu*b>Eha?gTGFJa'
    'bJ(i&wNG~M>9v}-t*2Lrnz+&@2ZyD(5}!Aobe1)r7bl)u6WLBJYjP!Wqp_k^HMt78CcW|BI<Kzp-#TLTI!w4i%7pAldegsh$PO)2'
    'N7Ebr6+}`*vee$nMUf1VJhi2AQ6xvCSujhhkO%*E`PKzrA!S0kcwLjIgGAq^buQ&l6-8nn<9uo`P!x$K*TpL>OeG|GDL%XKIh2_N'
    '%tC-+m6?3pJ#UZaG1(U900oKrKwSwc2z(7e<AIs01*IKA<8#WZJt?er8!jSuig(qZ_<C7((P=0%3-ELtB01;1sO7Iu{(iKsbncu5'
    'oU<l`BB{}1QKo_xCgR=yT2hJGMa-ysR@ImknNfgL(OOJ~%!U1GcxoxqvXi%Yc{JNGh}PV21Va;(JkAz06~QBG0=GKlPL~I_5E+p1'
    'p(&=V35LBqhKndnYFt$?MKD{~3`wosJN)qV@ob}rK$@|9Veh}PSdQ3sVH3Wx*cP$kVpxG#xv=+NS*%3t!sK8h)*f}R_gm-pKawG='
    'BhL;>X{(ZPnnOySJQJq^8LPBxQ!8U@kg--vky;^JgNzkhEu~_u^8MxwEl-}GL<dJ|p4z;vBvRv-)h@MYu_zLId>xM;MJ1$1WITS9'
    'm5?xglqNrZ9LvlC3!Nm<YtH}ta;oO!hMn{@*hw0b-pac$7QHW%Jm;b~wnMDF7#91Cv&?i;5sNJ?y%(G2B318~9lq^75pPg&!vTxq'
    '7wJr@hb)c7$uAi%E5RAJ(pX$oBI6T-S;eRIXt?9!f^l}dI2QY3uNIQBnl;$_y?Oe&IeI!~Tb!1_NldX<O`ALju{3yO&0v*UV_yLr'
    'J#oCAj8+931b3-@Z7P7lIxCW_T)O3IjkDM9y+3|`@?+XGJtbf$%uQ5hXQsHCU|cJyY&8F_eN8YXVkj4l7A>y{b^^iCc+qxM!4koG'
    '!E&{0z{js9B=#_1;^&=aXWmUFEy#pUU!84XE-Eo$2lL?~9xJI@OoGgKCBLr4q{!r1r(R(%t$h0EV9m&ybh0m-t>2q5Cj*W~2&kDW'
    'lIt;wbFp>DOa9^tUz&@J`^+t=%EgYu>s0isJQod%UpP&Li&ZCX%ttZO;eRJ8_Rl>{j}?njdu()PtHpFZDz@CS1!JZj72ECEnz61P'
    '6<h7XvN28dDyrQ*KJ5;J%lAV)#&u(=S7|#{o{TNGPwx~_fsAdpH<u)%W8ZgaYgL{cSq`_*4>ocY`FVfX?I$d~LQ=r$hNb<lqF9Yf'
    '^mNmv-J!zR7O^6^7P2%}AXcV=Tg9;wv0ZwtYqM&Xi7)=;I1VCCi-<H1P&E<BtcQ|JTpg&1PM!E%mZ_0xl7|BoWg295sU?YJnfN_v'
    '`nV_BuF5NW`K>$cnS+x{8rS>jv%Lk|nqb^rP{+v!v?>^r4|JRZ!0Uq17>j7k#${D7c#v8)3scnXnlPF<{&wB%H}2kF53bw~bX<z3'
    'l}Rl;tVCDXnB!?hDyq|QhEc~ejAx6us?cGwQJW}#kD2Op-1JFzdSTjnRdxSD$PZQ&&Q1`9N6}L}BCsHGq)f>8Fho-ciCZX{D1J!r'
    'gtMZ^=qYj9kg!@$2~B4@*DNu=vnEH(KkZ(=pVwJD)J$|Ha??dMC{BEL@m4!l)Pmw>J6$yDB!pFiLN&4t8YF^eX%>Z!oC!*kb2*GF'
    'wI+%6ZF`bwkJa)10p{X$J5&{hIZO%mO|(;TM+(C{zD6G%Ek^pjIE*6<qfZp$1BGBPuJMFrW9eg=S%5Fa($@t1zc}+~?)`ZpkH-yR'
    'JZYCg=|!<EV#QKKyC^pLD)M4jiCDE1M=y$1h&3Omg9Zh<h3-+UiTD3*zCW0)yY}}Fqpp;KvK_MRLaej`+alX7#4IbY9kTsp*&f;b'
    'Ld3KJ8>Z+zB};XU{R#Fdyw*f`+#JZ$h1h8&JX(9olN(Le!lTuv?ZxqE{m;(0Y%hS<i1!OsZ`JARGyY-Y#|3a_cx-iyr&H|f;Bjr6'
    'XCk?^UoAX#!7TQi-39R2C$hNe^%uZn)ni@0OU46fJX@SvTH~~S={GO_Fs7=3=YT_2&zq&0rGiw9-ukn{yxV$I><Ku%6qO>CCHLPg'
    'OvP@8i={oiRym@ZG2((mZ0;>hC$<(Nw)kdSo}5uCNJNX;w#oUVf<){<TalbiDoBjJWBP<3w(cyye!uB9E~KP!z@oWsZF<X+!dM&-'
    '$mG_MrLnl>o|n-q60sGrXcc5MheTXOEH)dtv;*p@Y@jEzz2EgmdQGNzgjdTjXFHC>39sU;XjLDt&=XMc(zNyhc<kX-<O36Z0X+J^'
    'DjInba{)XKK6QTin#Y5+yk-j>r(DxS?jLvV`2nW9UMt|KrD$xRx=p)db?DgHoE`DS>(jC0(el!CjNECJ9;w!$WAA60rA3o#rZ)QB'
    '_Gow8esdo}ho{9V9w%D;+5VZTE*ckacpud_ChMXx!Q01)*4$M_<F}4;t$AM=ja`vXjxhyqR~;&IZ|&Uycb^&=0oaq|_BzFYBVz_e'
    '9y-pT6$G{j6sb*F3jzfKqclZos{p|=_Eav-fUemY;}K`m#`{k&BU0N!mx19<lzkt$Myf9j>pjAvC30RChn*~|Y@(_1#;dZhaQ_LW'
    '7pw|jbqK@Z=<MJAHk}c}*cFljmiWk5(ykhoz>*|Mqa9m<5>>Diwri18Vk@MgtA~{mu{g6xrKpHCi1j(QJ(QURVlU=>0caudInn1<'
    'O|J>8JRQI8y%`VpyF$v0B&mtdqDX>BnwoPgilm5S7eO*a^3?2RQ6xv?!U<Jm)lMwW+ut`^H|}mXk7fgCqUz+9<AtdjE794I*wv%r'
    'N7Zq3*Vm)schzlj)~GNQ`;>TJpZBeoM(fqNrESAjIf28U_lK&17SODX)`CYnEtN-)v<V%rLhdS~vDatOP?c~|87&Zv4nK(!|7)Nn'
    'qO<39OFTeSE*;#b*X@sezw3VW_Lx!^R$)p`<6VUN+H?-H{gU(O+0Uv-4LZkX=h0H9*4L*Sq(`&eg4CyXKv#Teg~}@WW|tzP8_>q5'
    '7@e=sC`)ePD5G&h)RRGKt3I=U^D2f544o0n>yj0cF>*$%txMKO&SrCjGLryZm_{Ic&9uk8`|a*&^U^){Cyn{r#K){MB%VpZe0tWa'
    'ng$FEqTtCxk}7I|Mp5v1&ntTw4Y0~`ojN|LrUqDb+eKG#P3osLoBeLwiGjSf&r_R0Z%y*30uo*kJhCRRihQ;6oo&m4l|ZnGmR7l{'
    'V1r;Axrn4H*do|v?V?mzDfH65d#e)UznXpDJ^%5?*b+pe7$^&qY{RD#$!%#XuoY}CEmi#7PFH3}&#j}yTGgLhYh+{mki^S(Yp|hJ'
    'D6_N%uwBzC-ck?V&pQaXi5+iTb+$mRJR1j$I$GEjonBglt#K|uN9(*A(bi^jWJj?Zp=+}tKA_Xb@=DFxmHqrR3rWVj(Kn1<A!`D6'
    '(eegrYJ%aU4XNXerHro$?(tQ}vv$6(3I@Nz#FJ{hst7jNsElGum21^TrpFW*1M8ke@n*#;f=AW}R-{80jx$mZ99R?BB3O29O|Xr?'
    '7;2NYE?6Nr>%xUHvw&a92UydkySF7|C-pqi`h`ieBD5Z8u34D8DnWA%(nxI@wkby!X32`sDAGi}S~+Y0eqotl!`5y$GWXqd=)C9S'
    'h68Ov_ar?qD39(Vbd(xRYNIWp`-Q!2%A=u~(YPl)JBPhAnnGWyWJA(t2{1|NyYSnuyGMV!f8K8W{`U9X{<mAx*|$I4^X9?bzNvEi'
    'BKYmoe%Egv{P6p&8~%A!_ccN9;rV#<`@6StcY|Rb^t?iaM(s3>PTp)kUAv%A(2n5(D$=<2v$bQe&}z5<i$e(OKVLfm+R5ye%c0CH'
    '@ZOfo=K?JXENl!;<mw>Mb(o2HCm0l%vjW}1S&Fq3=uiQl-ZH$J0v;4NODa;APykYlh6|G3!?KzJ1QlTUY7Rq;;bJKuD9PGE`>6K2'
    'Blp0Z6wuAmBJDZ~X#8fHF0GTUqyQSuv;3a^A_`y~(DAagi_`&)wpJ%s%eG|Q#Nr>}M58MtOgN)bt9(k~4AyWHuK?o}aA*Wg<X7T~'
    'uVT0!a9!j}q6b|H*I{ezXx_ke*t+5XT|xj`L&x(Se}}cVYd=6hPobLz9fx;D@bbT2fpTwm+i&CF*W;R}!;LletG`0t4EG;+fmokx'
    'v+S|!8h+jL{^9PyJa31mn4G((hv)mv7W_Ml^};646!>f{u`*hgT4VRwT4D>Z{I9AdHapv<Rt$c&me|&<SZ+P4=BVh`!#mnxPiSQ-'
    'y7yVy;ds|3Ph<Hk?XX+7`md%P4hF4BMH@d$JA>NU<yIl9XgB=o?%*GWfz&SDc(Jc^WVuuMJT)B-`dr+r$iI-9*sVC88l8W-n%J+n'
    'HgzD_r>lt_i(lwi6kij=J=#a}@UVN^Yn9)$H$+?^D}Z?ug_#Jc2<C8VhUW1J7V%M~rNNMWI$T7#-JDki8w5vbue_}ahF9IXd>E<4'
    'w%t0J9yBF?{{8Kn+5hJXZ!zCbuf5;hH#<DvZ>QU8yls~rsx92s9d@VtMeoTj%*D$8{y=6IE{6YdEjY~X1ytaQMlQ_C7Uc>!EJq7M'
    'QVG4qxv;IkaKTbdzdV;AH$EL%)#3KO>&f)IZx?K#{iW;a;b>kfen0<+aq10!@%90)Kh^;L{q6AmU<Z5gpR4}|?fZn>'
)


def startup_bytes():
    data = zlib.decompress(base64.b85decode(STARTUP_Z85))
    if len(data) != STARTUP_BYTES or hashlib.sha256(data).hexdigest() != STARTUP_SHA256:
        raise AssertionError('Frozen startup maps bytes changed')
    return data


def mapping(start, *, permissions='rw-p', path='', inode=0, offset=0,
            device=(8, 1), size=4096):
    return dict(start=start, end=start + size, permissions=permissions,
                offset=offset, inode=inode, path=path, device=device)


def encode_maps(rows, *, heap_format=False):
    """Synthetic text projection only; the source fixture is replayed raw."""
    lines = []
    for row in sorted(rows, key=lambda item: item['start']):
        permissions = row['permissions']
        if heap_format:
            # Existing gperftools format uses '-' for a non-private mapping.
            permissions = permissions[:3] + ('p' if permissions[-1] == 'p' else '-')
            device = '00:00'
        else:
            device = '%02x:%02x' % row['device']
        lines.append('%08x-%08x %s %08x %s %d %s\n' % (
            row['start'], row['end'], permissions, row['offset'], device,
            row['inode'], row['path']))
    return ''.join(lines).encode('ascii')


class MapsRoleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.before = self.root / 'before.maps'
        self.after = self.root / 'after.maps'
        self.code = mapping(0x1000000, permissions='r-xp', path='/synthetic/target', inode=1)
        self.data = mapping(0x2000000, path='/synthetic/data', inode=2)
        self.rows = [self.code, self.data]

    def bracket(self, before=None, profile=None, after=None, *, necessary_pcs=(), buckets=()):
        before = self.rows if before is None else before
        profile = before if profile is None else profile
        after = before if after is None else after
        self.before.write_bytes(encode_maps(before))
        self.after.write_bytes(encode_maps(after))
        heap_rows = a.parse_maps(encode_maps(profile, heap_format=True), heap_format=True)
        return a.validate_map_bracket({'maps': heap_rows, 'buckets': list(buckets)},
                                      self.before, self.after, necessary_pcs=necessary_pcs)

    def test_full_786_original_bytes_shape_and_roles(self):
        raw = startup_bytes()
        self.assertEqual(len(raw.splitlines()), 786)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), STARTUP_SHA256)
        rows = a.parse_maps(raw)
        self.assertEqual(len(rows), 786)
        self.assertEqual(a.map_role_counts(rows), {
            'file-executable': 112, 'file-non-executable': 456,
            'anonymous-executable': 28, 'named-executable': 2,
            'anonymous-non-executable': 167, 'named-non-executable': 21})
        self.assertEqual(len({row['path'] for row in rows if a.map_role(row) == 'file-executable'}), 112)
        self.assertEqual({row['path'] for row in rows if a.map_role(row) == 'named-executable'},
                         {'[vdso]', '[vsyscall]'})
        self.assertTrue(all(set(row) == {'start', 'end', 'permissions', 'offset', 'inode',
                                         'path', 'device'} for row in rows))
        self.assertFalse(any(row['path'].endswith(' (deleted)') for row in rows))
        # Strict source rows retain the original device tuple and path text.
        for line, row in zip(raw.decode('ascii').splitlines(), rows):
            self.assertEqual(a.PROC_MAP.fullmatch(line).group(8), row['path'])

    def test_full_786_raw_bracket_with_synthetic_heap_projection(self):
        raw = startup_bytes()
        self.before.write_bytes(raw)
        self.after.write_bytes(raw)
        original = a.parse_maps(raw)
        heap_rows = a.parse_maps(encode_maps(original, heap_format=True), heap_format=True)
        bracket = a.validate_map_bracket({'maps': heap_rows, 'buckets': []}, self.before, self.after)
        self.assertTrue(bracket['complete'])
        self.assertFalse(bracket['atomicObjectSnapshot'])
        self.assertEqual(bracket['beforeSha256'], STARTUP_SHA256)
        self.assertEqual(bracket['afterSha256'], STARTUP_SHA256)
        self.assertEqual(len(bracket['fileExecutableMaps']), 112)
        self.assertEqual(bracket['mappingRoles']['before'], bracket['mappingRoles']['profile'])
        self.assertEqual(bracket['mappingRoles']['before'], bracket['mappingRoles']['after'])
        self.assertEqual(bracket['nonElfFrames'], [])  # No actual startup PCs exist.
        changes = bracket['mapDifferences']
        self.assertEqual(changes['beforeToAfter'], {'comparesDevice': True, 'removed': [], 'added': []})
        # Seven nonexec shared rows differ solely in the formats' s/- flag.
        for phase in ('beforeToProfile', 'profileToAfter'):
            self.assertFalse(changes[phase]['comparesDevice'])
            self.assertEqual(len(changes[phase]['removed']), 7)
            self.assertEqual(len(changes[phase]['added']), 7)
            self.assertTrue(all(item['role'].endswith('non-executable')
                                for kind in ('removed', 'added') for item in changes[phase][kind]))

    def test_full_786_synthetic_pcs_preserve_30_unknown_non_file_regions(self):
        rows = a.parse_maps(startup_bytes())
        # One synthetic address in every executable row; these are not samples.
        pcs = [row['start'] + 1 for row in rows if 'x' in row['permissions']]
        result = self.bracket(rows, necessary_pcs=pcs)
        self.assertEqual(len(pcs), 142)
        self.assertEqual(len(result['nonElfFrames']), 30)
        self.assertTrue(all(set(frame) == {'pc', 'mapping'} for frame in result['nonElfFrames']))
        self.assertEqual(sum(not frame['mapping']['path'] for frame in result['nonElfFrames']), 28)
        self.assertTrue(all(not frame['mapping']['path'].startswith('/')
                            for frame in result['nonElfFrames']))

    def test_nonexecuting_deleted_proc_and_heap_paths_remain_verbatim(self):
        deleted = mapping(0x3000000, path='/synthetic/data with spaces (deleted)', inode=3)
        for heap_format in (False, True):
            with self.subTest(heap_format=heap_format):
                rows = a.parse_maps(encode_maps([self.code, deleted], heap_format=heap_format),
                                    heap_format=heap_format)
                self.assertEqual(rows[-1]['path'], deleted['path'])
                self.assertEqual(a.map_role(rows[-1]), 'deleted-file-non-executable')
                self.assertNotIn('/synthetic/data with spaces', [row['path'] for row in rows])
        result = self.bracket(profile=[*self.rows, deleted])
        added = result['mapDifferences']['beforeToProfile']['added']
        self.assertEqual(added[0]['mapping']['path'], deleted['path'])
        self.assertEqual(added[0]['role'], 'deleted-file-non-executable')
        self.assertEqual(len(result['fileExecutableMaps']), 1)

    def test_executable_deleted_rejected_at_every_capture_position(self):
        deleted = mapping(0x3000000, permissions='r-xp', path='/synthetic/code (deleted)', inode=3)
        for phase in ('before', 'profile', 'after'):
            with self.subTest(phase=phase), self.assertRaisesRegex(a.ContractError, 'Deleted executable'):
                self.bracket(**{phase: [*self.rows, deleted]})

    def test_deleted_path_does_not_relax_other_path_or_inode_rules(self):
        for path, inode in (('/synthetic/data (deleted)', 0), ('relative (deleted)', 1),
                            ('/synthetic/../data (deleted)', 1), ('/synthetic/./data (deleted)', 1),
                            ('/synthetic/back\\slash (deleted)', 1), ('[unknown] (deleted)', 0)):
            row = mapping(0x3000000, path=path, inode=inode)
            with self.subTest(path=path, inode=inode), self.assertRaises(a.ContractError):
                a.parse_maps(encode_maps([self.code, row]))

    def test_nonexecuting_before_only_after_only_and_profile_only_are_reported(self):
        variants = [mapping(0x3000000, path='/synthetic/transient', inode=3),
                    mapping(0x3000000), mapping(0x3000000, path='[anon:transient]'),
                    mapping(0x3000000, path='/synthetic/transient (deleted)', inode=3)]
        for transient in variants:
            for phase in ('before', 'profile', 'after'):
                views = {name: copy.deepcopy(self.rows) for name in ('before', 'profile', 'after')}
                views[phase].append(transient)
                with self.subTest(role=a.map_role(transient), phase=phase):
                    result = self.bracket(**views)
                    self.assertTrue(result['complete'])
                    changes = result['mapDifferences']
                    found = [item for delta in changes.values() for kind in ('added', 'removed')
                             for item in delta[kind] if item['mapping']['start'] == transient['start']]
                    self.assertEqual(len(found), 2)
                    self.assertTrue(all(item['role'] == a.map_role(transient) for item in found))

    def test_nonexecuting_missing_between_stable_endpoints_is_reported(self):
        result = self.bracket(profile=[self.code])
        changes = result['mapDifferences']
        self.assertEqual(changes['beforeToProfile']['removed'][0]['mapping']['path'], self.data['path'])
        self.assertEqual(changes['profileToAfter']['added'][0]['mapping']['path'], self.data['path'])
        self.assertFalse(changes['beforeToAfter']['added'])
        self.assertFalse(changes['beforeToAfter']['removed'])

    def test_nonexecuting_replacement_range_permission_and_identity_changes_reported(self):
        for field, value in (('end', self.data['end'] + 4096), ('permissions', 'r--p'),
                             ('inode', 4), ('path', '/synthetic/replacement'), ('offset', 4096),
                             ('device', (8, 2))):
            after = copy.deepcopy(self.rows)
            after[-1][field] = value
            with self.subTest(field=field):
                result = self.bracket(after=after)
                delta = result['mapDifferences']['beforeToAfter']
                self.assertEqual(delta['removed'][0]['mapping'], self.data)
                self.assertEqual(delta['added'][0]['mapping'], after[-1])
                if field == 'device':
                    self.assertEqual(result['mapDifferences']['profileToAfter']['added'], [])

    def test_missing_any_required_file_code_in_each_view_fails(self):
        required = [mapping(0x1000000 + index * 0x2000, permissions='r-xp',
                            path='/synthetic/' + name, inode=index + 1)
                    for index, name in enumerate(('target', 'allocator', 'libapp', 'flutter'))]
        for index in range(len(required)):
            for phase in ('before', 'profile', 'after'):
                views = {name: required for name in ('before', 'profile', 'after')}
                views[phase] = required[:index] + required[index + 1:]
                with self.subTest(index=index, phase=phase), self.assertRaisesRegex(a.ContractError,
                                                                                       'executable map'):
                    self.bracket(**views)

    def test_file_code_range_permission_path_inode_offset_and_device_changes_fail(self):
        for field, value in (('start', self.code['start'] + 16), ('end', self.code['end'] + 16),
                             ('permissions', 'rwxp'), ('inode', 4), ('path', '/synthetic/replacement'),
                             ('offset', 4096), ('device', (8, 2))):
            after = copy.deepcopy(self.rows)
            after[0][field] = value
            with self.subTest(field=field), self.assertRaises(a.ContractError):
                self.bracket(after=after)

    def test_non_file_executable_interval_gate_remains_strict_without_actual_pc(self):
        code = mapping(0x3000000, permissions='r-xp')
        with self.assertRaisesRegex(a.ContractError, 'full maps executable'):
            self.bracket(profile=[*self.rows, code])
        with self.assertRaisesRegex(a.ContractError, 'full maps executable'):
            self.bracket(before=[*self.rows, code], profile=self.rows, after=[*self.rows, code])
        # Existing endpoint-only unknown-code semantics remain representable.
        result = self.bracket(before=[*self.rows, code], profile=[*self.rows, code], after=self.rows)
        self.assertTrue(result['complete'])
        self.assertEqual(result['nonElfFrames'], [])

    def test_actual_and_necessary_unknown_pcs_require_stable_executable_mapping(self):
        code = mapping(0x3000000, permissions='r-xp')
        stable = [*self.rows, code]
        pc = code['start'] + 16
        for actual in (False, True):
            kwargs = {'buckets': [{'stack': (pc,)}]} if actual else {'necessary_pcs': [pc]}
            good = self.bracket(stable, **kwargs)
            self.assertEqual(good['nonElfFrames'], [{'pc': pc, 'mapping': code}])
            for change in ({'permissions': 'rw-p'}, {'start': pc + 1}, {'end': pc},
                           {'offset': 4096}, {'path': '[anon:changed]'}):
                after = copy.deepcopy(stable)
                after[-1].update(change)
                with self.subTest(actual=actual, change=change), self.assertRaises(a.ContractError):
                    self.bracket(stable, after=after, **kwargs)
            with self.assertRaisesRegex(a.ContractError, 'Necessary PC'):
                self.bracket(stable, after=self.rows, **kwargs)

    def test_actual_pc_nonexecuting_or_unmapped_never_accepted_as_data(self):
        for pc in (self.data['start'], 0x5000000):
            with self.subTest(pc=pc), self.assertRaisesRegex(a.ContractError, 'Necessary PC'):
                self.bracket(buckets=[{'stack': (pc,)}])

    def test_actual_pc_duplicate_mapping_is_not_hidden_by_set_comparison(self):
        self.before.write_bytes(encode_maps(self.rows))
        self.after.write_bytes(encode_maps(self.rows))
        rows = a.parse_maps(encode_maps(self.rows, heap_format=True), heap_format=True)
        rows.insert(0, copy.deepcopy(rows[0]))
        with self.assertRaisesRegex(a.ContractError, 'Necessary PC'):
            a.validate_map_bracket({'maps': rows, 'buckets': [{'stack': (self.code['start'],)}]},
                                   self.before, self.after)

    def test_malformed_partial_ascii_overlap_and_numeric_ranges_still_fail(self):
        good = encode_maps(self.rows)
        bad = [good[:-1], good + b'\x00\n', good + b'\xff\n', good.replace(b'rw-p', b'rw-q'),
               good.replace(b'08:01', b'gg:01'), good.replace(b'00000000 08:', b'-1 08:'),
               good.replace(b' 2 /', b' -2 /'), encode_maps([self.code, self.code]),
               encode_maps([self.code, {**self.data, 'start': self.data['end']}]),
               encode_maps([self.code, {**self.data, 'inode': 2**64}]),
               encode_maps([self.code, {**self.data, 'offset': 2**64}]),
               encode_maps([self.code, {**self.data, 'end': 2**64}])]
        for index, raw in enumerate(bad):
            with self.subTest(index=index), self.assertRaises(a.ContractError):
                a.parse_maps(raw)

    def test_maps_file_overcap_is_rejected_before_parsing(self):
        self.before.write_bytes(encode_maps(self.rows))
        self.after.write_bytes(b'x' * (a.MAX_MAPS + 1))
        with self.assertRaisesRegex(a.ContractError, 'cap'):
            a.validate_map_bracket({'maps': self.rows, 'buckets': []}, self.before, self.after)

    def test_data_differences_do_not_change_all_four_heap_integer_counters(self):
        source = a.ROOT / 'fixtures' / 'historical-q0.heap'
        original = a.parse_heap(source)
        raw = source.read_bytes()
        transient = mapping(0x100000, path='/synthetic/data (deleted)', inode=9)
        addition = encode_maps([transient], heap_format=True)
        path = self.root / 'synthetic.heap'
        path.write_bytes(raw.replace(b'MAPPED_LIBRARIES:\n', b'MAPPED_LIBRARIES:\n' + addition))
        changed = a.parse_heap(path)
        self.assertEqual(changed['header'], original['header'])
        self.assertEqual(changed['buckets'], original['buckets'])
        self.assertEqual(changed['header'], (2, 320, 3, 324))
        bracket = a.validate_map_bracket(changed, a.ROOT / 'fixtures' / 'reconstructed-q0.before.maps',
                                         a.ROOT / 'fixtures' / 'reconstructed-q0.after.maps')
        self.assertEqual(bracket['mapDifferences']['beforeToProfile']['added'][0]['mapping']['path'],
                         transient['path'])


class MapsBudgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def sized_file(self, name, size):
        path = self.root / name
        with path.open('wb') as stream:
            stream.truncate(size)
        return path

    def test_twelve_maps_count_is_inclusive_thirteenth_rejected_without_deleting(self):
        for index in range(12):
            self.sized_file('%02d.maps' % index, 1)
        self.assertEqual(len(a.check_sidecar_caps(self.root)['files']), 12)
        extra = self.sized_file('12.maps', 1)
        with self.assertRaisesRegex(a.ContractError, 'total cap'):
            a.check_sidecar_caps(self.root)
        self.assertTrue(extra.exists())

    def test_ten_mib_aggregate_stays_inclusive_with_twelve_maps(self):
        for index in range(9):
            self.sized_file('%02d.maps' % index, a.MAX_MAPS)
        self.sized_file('09.maps', a.MAX_MAPS - 2)
        self.sized_file('10.maps', 1)
        last = self.sized_file('11.maps', 1)
        self.assertEqual(a.check_sidecar_caps(self.root)['retainedBytes'], 10 << 20)
        last.write_bytes(b'xx')
        with self.assertRaisesRegex(a.ContractError, 'total cap'):
            a.check_sidecar_caps(self.root)

    def test_individual_one_mib_and_original_four_heap_budget_unchanged(self):
        path = self.sized_file('one.maps', a.MAX_MAPS)
        self.assertEqual(a.check_sidecar_caps(self.root)['files']['one.maps']['bytes'], a.MAX_MAPS)
        self.sized_file('one.maps', a.MAX_MAPS + 1)
        with self.assertRaisesRegex(a.ContractError, 'Maps 1 MiB'):
            a.check_sidecar_caps(self.root)
        path.write_bytes(b'x')
        for index in range(4):
            self.sized_file('%02d.heap' % index, a.MAX_HEAP - 1)
        self.assertEqual(a.check_sidecar_caps(self.root)['heapCount'], 4)
        self.sized_file('04.heap', 1)
        with self.assertRaisesRegex(a.ContractError, 'total cap'):
            a.check_sidecar_caps(self.root)

    def test_maps_limits_do_not_change_other_acceptance_budgets(self):
        self.assertEqual((a.MAX_MAPS_FILES, a.MAX_MAPS, a.MAX_MAPS_TOTAL), (12, 1 << 20, 10 << 20))
        self.assertEqual((a.MAX_HEAP, a.MAX_RAW, a.MAX_SIDECAR), (1 << 20, 16 << 20, 256 << 20))
        self.assertEqual(a.MAX_MODULE, 64 << 20)
        self.assertEqual(a.MAX_ARM_ELF_INPUT, 1 << 30)


if __name__ == '__main__':
    unittest.main()
