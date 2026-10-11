"""Offline identity/symbol separation; never run captured application/package ELFs.

The 113-row fixture replays captured metadata, not nonexistent retained FDs. It
cannot independently re-prove remote loaded identity. Separate real-byte tests
cover SHA/FD/PT_LOAD checks and the exact official tcmalloc GNU altlink payload.
"""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

import dependencies
from application_contract import ContractError, map_key, validate_module_records
from elf_identity import BoundModules, elf_metadata, elf_metadata_fd, file_identity
from test_inplace_elf_contracts import BUILD_ID, fixture

ALT_ID = '99' * 20
TCMALLOC_SHA = '90af33bd2717cb8431f39806f28f6a486f8d2e24d80153d503967315413f2ce3'
TCMALLOC_ALT = (b'/usr/lib/debug/.dwz/x86_64-linux-gnu/libgoogle-perftools4t64.debug\x00'
                + bytes.fromhex('c7db8991070c2644f5a9378f03bfa160be62ca86'))
# Full list, minimal fields. Historical GNU altlink names were not captured and
# intentionally remain unknown; the test does not invent the ten missing names.
CAPTURE_SOURCE_SHA256 = '17fd231e3cc8b10efcb322e5b7993e17a63ec9867cda919a7fa5201e86efe124'
CAPTURE_MINIMAL_SHA256 = 'f0e5da9f31e99a6c197ca981075a9acbf4d7d5da28a9b0e737b7d27f82fd382a'
CAPTURED_ROWS_B85 = (
    'c-'
    'qyyZEqw=jwbkD^6PeH8EIxTV}IMb9V`Zz0~Xi7p@GGsV6R!4QcAg!vL~wt^WTqj4@vG(?cVO*UbQh*=;}048DR?fV|+*>AO6pO|B'
    '%1k-'
    'PeDvAO83ObBLy4kB)2VK2|JXDpem$;hsv)H322};SV43FE8!+!ykbR(;q(6mcM=e=ZF6I;g1jB?(g*rf4M8|!yk#P@v{8o;rW*@A'
    'O841|JNTre17=$-'
    '}Kw>?;d`B{q~>I^FMvbt=3lm+xtuPbpPD`@Zs*^vC2!ai=Nr(`s=rs|M7T#SALN_Keu$>>PP({UOuL$mpj?#i)`@zG1dR;F6kbfa'
    'UOyT!TG>Anp*v@FMoQG@BjAo!yjLszO~mc|8s2*FLy7${Ew%{zqE%}+n4r|YI;fX)yMwfkN^Im%fA2g%a{Ck|EH23{_n>xU+>#X8'
    '^8TO{_x>zdihB<_rp(*U)m2(-'
    'yR;?(+~gl`1JD+KfbgtUw`=0zC1qt^6~NC<m(@QYWH8oe1DfyE<Zk`m%G2T9|zNq^0o5m`B8qHuP^^1+mlc5-'
    '#?`LyU(&QH+=H_?!Nu$?yvIB5HQO6K7E#-+3A+`J*KwD-k;mchd-J>eE3VM^-2EpAAeYWJtTg6J%9CjgYEV8#=m)aNnNbGs-'
    '?wE4yM=FjG(`%%WLXl<u!dYZ?8%7*CcfBuL%(JEiNw#K9c(nc_5#EO6W;`Tee1*s6}QQh#W`L!6f94-'
    '67h}4xoW4DRwWvsz6*?l}EA}>qBTHzb1LgUs4_)^luN(-'
    '@bl*e0pj1Px6QR_C=no^z_T{g#W3Pm%GP@XZ=?F(cVFrYp32?kHul}IZ`W_y6q*Tl-'
    'V*=7F^o$4nnfg;tYfbU$0yq<A1vE|F1mocMq+;q44Ls2Yt16f$4|I=Z4j_;1VLRkBJ@j;H|@m0U}VxRAU9#Q)_Y>)Y5|C(1R_;5k'
    '{L>U+eMPlb#oU12OVR5C0o}q8~mBRQk)~<Nfo;B%kSBN%}E<l)v!&!}CijKYvUwFHd**n|}EfQ~&$hU3>Yle*5xO!So*|9Z%!Q@P'
    '0ax^Zw}RMBq&{&c*+;r_<@5^_GLnvd6_UVX*BxxY&_jI=DvLp@Yjfv$)H__IAt&9^LyfqpP)J7WA9{_UVO&BgM(72uzb5qZM~HJH'
    'gIC;y-'
    '?ZxoB(dJ^N&;fu7_M7k`nsB}xqw$3z6h;)F(+fWf%miAazf@U)9a%<y=5wZ9F>i}5!?r2MGgzW?x@+z(%$9`zZLuRm1zKLOt>0Nc'
    'Z7Ik-2ohG?Bzqz$8SAN)KAd2W{g_-cK9O*AgPzwWSF10h?BZuzhnt*@_50<8&L#^uVZM>25<iq-~sMkh!#-'
    '~+r<6j=*jh%+?i6hmg0N=pu_p#TXp%ik0K+pV>wId0W<3i6A~u98iiY7ufJ^rIL&2aSd0jcZGmQ^-wVRtT!i+14VgkYR#CaA>^8-'
    'w%e)9QK%Uo;gqOf11zl#OK#VuXynq?@uEcGHCqL!~SMoN9V6zR{ViQV;1rGYJLNeAv6<+Ue;@G0cO#o4W@TK?!=+F2_?ULVTPhgQ'
    '9j`4VgzjBt+3aOEmQ6x78^-;c+ah~0MZ+AJb`1$E*T7L8|ITx<S002JDMD*2<;EO*w9M#2AjsooMINTV&2gtq)tD!-'
    '_N7*K`5a|iFQ2R7Ww>pP|`2`_}uR0H}<H3vV8ZCU+=$(@7wD7LR@Baqituv9D{?!h<P*~32#Zl*2Pm`u)R6cNa6iuht=ACJ>Vivi'
    '6%g`a@4p9Q3f<Kh<5Uh9D*Fkt=Z<C_&0Hg&JcN%oQYljPHtZQiQZDF-'
    '6akzj?v^OVf8r>6>pn*VCNHe=!S}Hqd9Lf7LyI7D4wr!=@W++WyilGM1%Q9Ac}5CU;HP6=>4~sm-'
    'h7Izdr9oraUo=S)$Rl51A;ea|xKE?MOt(%c(3rn#$s3NV1!`&Y9oz;+*D)bfG}ZH8}B)CZv)LR1?K_b_oU1h?_KEg%10WB`_><It'
    '62jWv<D$a+1@u*7sb{LJ1Y4D<q*HT6q)+sQGAHE196>DI&p`AtL_${AN51N<#u^<Ni~Ea`c#=Uw+;SN+Aet2&ew`BmZXJn`M?5z)'
    'mvPzsfYf+FxJy?Ts$4uEfQ!g31XuqQw-kvk_n#*#%AgPW+vG!AAqMn#4g`$>M;J(a9S~oJe7sB8rAtqRSbA1&G2jL$%g0BypC|vx'
    '_xZP1IP~pbrwzqGeZ8w7!KJs`E}@V{DXY^Be?AI2bIW@7`gmg?l8S+1QHnz8ZP9U1;({&^v;y3E_A3sqhc@RL|r6)qfuNetWwA@j'
    'iWfC_lAhtk>}}n;dOB(>)lMlRbm&h#y2+PV?aWQfFVbbsG9!bKco8GmlKsUVGSLq2}xflN=AiEkW330iWd`YT2gZvvbH^+^*#=7_'
    'BXUxK;`wn(F;I_^io^@Atlk9F2FbJ4g<5YuH1J#!y!NUBf#*(Sdrr-_N}s$nXf&k$9WrKVy9Jp8%fXQlC<PeEQtBInyc8yY{3EyY'
    'D>22QH#;v>idAvdqQYFiayvK#UVUs;gBLPI$yR3cZ`YF8g@JbGr@Pe3vLvBEDX-'
    'c*@M)a|xvsXR|Az3p{ca3fzSM26@;F#vHg*Zs8;^sg62VCws}=WS_ci#^)A#rqrRi(o!fq@seoe(f)_r<iCF?PkM(UABqr+fM6~k'
    '@k9Ee7pdEJ^l8|DUWsl2v~@B3iY?3PULyIA&%Zpsv@ajqegB)jR?~OJ{=V7TZ_h(n#Sh;j{YdWP0N#)CG5&C0FAK4JBqzS}6K=b!'
    '^tgNrIM{a5-+=NvS|q<0>!JHf2D@^tIv6L66miB!Wx0MXEMHmz!t~A-5zW+*4$HYGMU$|W$Ph{ptQyQL4-'
    'H#S7EN!^#mPzpDddyc1q(eIS=DaY8m#FY3^$WomylSzsWlmT3l2kPIXgr0RnCznyu$;(V>n1)i>E+XaAj<ecrwf&ylq4KAgpJjI|'
    'N|}aul22I|a22;k*1#|NUPSxgh_VZI_)AWG%w?V%&#c8)>=N;9@-JBY~HbU>D<CNNjNev0=5w6)-'
    'MebGoTlr!fuwdh?^J8FFI~LYp%t!6TVw5rHH|lyH|xE2N-tDNvJ8UU}|f!^SygF7i<~0Z%;#xji;W1)DHiA?-'
    '17>KR!MG3dcT9PWZJmT8PCj2YuO-'
    'Zut`-9g@Y2HkBt+6~<pk3v@-is5$qcA)#?m-d_#zefMvgkLh`Y2`xH?@vFG5%RR?e=pYef&w?igRa)@Z6qRF-tB07_mc8JPU;|r<'
    'yuOMF)U_^C5)d&5GdZ%OkSI#GKVRSC2F=!@L8jw23osQqpvYo8#5W<%+BSW#O<aek5NH+w84eqnz*G9yE!YCE!hcG#YEMc6osTp*'
    'vu?!LmuE<S^?0C<jEDQ3t-P-'
    '(OUcAtQ)ce?=arBp?xrR(IX#%u>(D8hNt{SVEpQU!$tthL%VWo@@m~*ryN%+m8an^>NWo4j&xYA)dYcG2JyxCPS3qJ(|b}~uBFbj'
    '+F`MB+00zAlVALVJ&em4h)G~7xCiS4RXISajY1xi$+Ai&CULlee2T&*p?7iwdOcLF7BG8*Cxyb<S>fr~X9_I4h(5Cs)+ngq(1Or+'
    'S3MI=s+R*WpF^WTQ~5rOr|vt5w{2*zFD9fTAcp9Tu`txZ+zg2S=}&*bAqL*eq!p;kIA+>^M=L&vR~)gO-qKo}7V;0Pl~)da`N$b<'
    '$9OdP<#Ivt(=3+6v6C}rSk0j8ssmF(i_vCkE~o5J{B3HX<y0v(d8kp1y)+}yUnB9*-'
    '4)wgan|Ouc(jn68ik<C0V2V7i5W|)B&5BzR6%@w@{T7FFxU{z!mdFdg@)kV0dL#Ueg|xiI$-%d{N6W4>)8GCJ_-'
    '%SuZ6%zQdlNfwu{KUSdRt4OaYf`EN1n%`buX0!m9~$q-'
    'F5NFsrq&b|`~>eQCW4GFSY$mzZp5Eir<rCEDU;)w@rvO1LY4E=0k0?BaEzUJ*4gwsx(*a3}HS7DI21gXt72n$%i}P5f~xwHAVcP-'
    '|dsXLq$jP<RG@EeS1V`K8RW(3^I&7r%ouID}scT9s*T3BL#8U^hPN3zxW~ac}J++Lb)?#rj4@{lKwaxu~vI8v^3;W$wlJ9tUgh-'
    '6Rgy<=Vd8kX&9WV&rMLF*4W*Js+1d9Q&S}Escq>24QNYQXuTvdUo<$=w+`Bm6HjryV|X-'
    'u473oj=A?_>`A4@0vV;3XrQn$!UJOJP_k_tZI_?eYjkes6x#k{-81j0=pgZu7Gcdf^tK)C_QL>2{V-Z$#v8(My?d5#EI;i-'
    'GSaLV|5ud`^IH6^)sB{zlhUu&H&ke0=_ETeEZ5j{uq$QLqj6HIHTCx6ay94e%yL=_T$r<JgFM0WxSZcCB?E~y*eWr`kZp}kpv;_o'
    'EIG$6L3Sw;6B1GOrgGEoYuOYAiPX-jg6u_N@gRXXNO-'
    'C@SW!5A_AO%2!p%~WE7?r^vIMf;`4G>6Gz8XCF&K*MCb_Lmo7xL$Jm{KHp36(e#En4uU;gF)`+tU@*nEO*)Y_7D-'
    'YxgmOuk_sqUC(|XcvJIVpKmlWvuc>5hjjQzak&<RgIy`tlyWb9P8C#G3-'
    'Hp{k7_UT;giAP&gKAI5jNA$VpGcxlqly$CGYeH3pZL79Jo(+2=+f#}<OOsTU-'
    'P`WnlQuuSnW^dp>eed7XZX~GN}+cvbDw*I=?Z7XecvQNC7l+m97K7KEGO#W^TJ#jgh8*Mx9Ud>{+&0soGH37@K8m6pzPZgD0My{L'
    'njYFhKn5ng?^NL`SFcX4!G{@0nB128nK(3<qojQXM)dIp9VwY1!{+Q7PXEOy8TRJJhD_+6-'
    '49Pa=C6mpy$qA8Dw&Fp2kS#jfterH%f!;X9bHYq*@fFV)-'
    '2A$A+m`m>HORJ)!8HnL!=YW{cHpW|rB7}nR5^xaO@@ncXPI!6hhUMEzFObAtI<uaEXU>QtB*aZ3o+)!`bHcXr{zxLa<xc{mLUx6W'
    '~EdZB2Jp{F6%ih_1RbXa;{wDA$4dHVeL_1TUeN<gqIpzT1b&QM@O#KT)Y)WES@Nwq|#8u-'
    'J=u01SfAV@ncot8!rr5dk8pnpRw@F?MC8rZd;v@Q6v1;;XK>BX+yhVjK^RcNF}4(?J&|mr*9*Sw|ZO)E7gjyKh-'
    'O7_hOD{v>oxe(Jfxj45nkL<KPx66vMR30eqZx(lKAv`9~qWHQ62|Iw_D!Z<f1py=#qRG^J(?HW;6iZ$V<FBr#R489W9}ADzUJOKK'
    'h(gp_=$MM6V4Fl;4lgrZt{ZBWDk`Y`3l!~O9Y99d2tVZvh)Z;}$)w4t3~W#oe#S;8IX;tgHR{8`ns9-'
    'r@C+CG|$ak*}HwCzj>@v@HFXgdVj<<5XOty|dD=)T-TH!En;iw2rDzh0>zQSc?iD%>v%?@XRkbv-u0qyw%dI?NDCDoI?d-'
    'llS==!5(jTJe?OB*+RIPtfEz=)NZotq6o9498@$ms1DDw^woO?~rx&EXZ2YCR&gfVqOWcX+wJ<YfU%|+32IcCCGkzdVYL*#p||~f'
    'J<U+p+IQA?jlO`ungGIcnDo<)rhlV#C_!zV1QQSUgGq8ncky1cYTd&I9Jb3+=gx1sbWaNf}RXX0L!HtjzW?pkW0=Rhs}_$s#Qu*8'
    '7T}*^^7tIE5LD8JZ^T?u<#6@HG`Y9FtP;1g1uXSnX5f3yaoB0DTXk=McuZc-'
    'M9sN7`NnYxFOuu^d)_6`<el8rIr{EloCsv0n2_C4<@97UEJhgI&=~&*Z<FSV*jq6?VZ8&T$_;NCX|nCW<e_jWrof)8(i%UoM)9wt'
    '89WeA7=5(wl;SXHMU-'
    'b!~`2XCg7erNffPpL$)M}R#hgz!Jt_B+I&a<V2k=2UeRiinDO>1eY|NyyW?1QIF8kJTD&2+ekot~MY3*11IfYuu62sbK6bPnQ)*g'
    'HLeVULysvAW+)AP0w2Qz^b()52jX7W`R1TF?#aq0#GbUv)RS2*=l-'
    ';F_;%8f?RD}@>xXDY9>stZa0@{31ol<NP8MEN0RP^%r3I$A!l6S&1QV&t~+A)@CeM9gkb=o<wAjjWOradiF+O(mafVIXP^{>%-'
    'b3@%ae{SDj_9c*EtwIToR46&i%k{w*<3UXb1Ix+oi}6?okbq~A8e^P_<;cS_Ng4;OQkx6=itm(1l9`;a-'
    'X;!IqPAK=T#u{H0p%Dv)YiOk<&;v$S`q{adSTn$NeXL1z-'
    'tYtoqV<!Lqb=(IJv@PFq_WuYt7jgoVwbf+U^Wj3jz$XPW4_U$lbP~{UPna!X$}j(G7>ytw6WmeQ(bSUb~qYdsvnP9&LLogyV`Z;%'
    'Gc1662T8n9+7jWjI8;gxYzrqUAVsw<?P|OC7Vg5)R#2)fqHkD<TJRJ}Gz~#o5HdsX`~#tB?S!l@RP$H5yE>C*AY-'
    ')VU=q<TD%L<=C_fh>90tD!dS*{PfxRJh`yd>#mbP>ja3Fjh~kuZQIaZ&>D9%o+U7&g!`?4_HOjHTLHVK;eABHTi~$_*o*Ptt;|Z^'
    'ILs2q`#dd}l^fbw5-'
    'M1j6b%lm8EBIS>janxr9rZCmfNmUDO`)^+^cO7v?eGb$KZMc;fmgagl7iCc#@~hCiUL1M$eUFY0;VzHTRXRX-'
    '+<khDNCTv=_&nB`70@6pBw}ntR%98`__Q;-'
    'e&)0>BNaQT+Mtp*^K9Y3FUvN^=_e{oSx~d@h&%4z^=iC|u4$;W6($bdD`}*;z#e47wceQ+r_Eyk1M|J)rBZ2Ui>#c`ACM1kg$&q1'
    'jISN-'
    't&{jNzR?+m=!gyx?1ovXipLoE)omdU36GgQ~h_T<h|d#Gpd|Hidwbtg#E;oK@gU7$Vqs1=vj++FQiv=<o%tyf3*M0_;<Is83_xD{'
    'fVwh|4vMqir`_S1x--'
    '<Dr_v5EuRIXnWW8o>m<WtF?waT+Bqxv?GPcP2yPzi>~6?TnJEjutcw3RsDU_{xNG^<8DjuCR=g88IW^ElgR;!&*`QU7UQ^{)iH<A'
    'TP8}$d(*^=CDU4RzIWi(B_=nh<7=i@v~*HDYlSp$uy%e!yKO&vF$;$)8I9J5(+x4>r}j|W<%ZU71?@_HhhTp#Ba&a%jJX((fYt&p'
    'E4B@`W1t1Vut<(!dKfrkCpW)(Z7?Ut=naR^Of$x1D#m*y=EVvfR&78-RwB2kVr~-'
    'a8hOB}6`K<I>V+VdlP2V;V6*nVx7_9F69Up9$m^5Iv1YPPz8Y#u6LO3=2w9!sYe^#1a8*~aZ9DtBT;XuLfFEmgZw0mAd!)a7*~g5'
    '>lXhuTq&d*1&MQh!qw!G7z={$E%%`{QN=r|hW@)9u3YaHzsI*Xe?rK9VSXszPvl(qHSdv)8o0eEYqQWMNtMvgb4^<Z#TdJ6Ssdi|'
    'aJ8KkxD~575f`k}DY}JB<ths8nbI#6slNkEsmKK6BCzV4vop0yi`kHpzj&`S^EFF|cb-'
    '|2+dp82x^z!pZ#p}?~D*H3Mu@laLTj@_9jXUpa<?R>a+Kcg6ce+GK%Ow^U<9jG-{KTD)%he-iMWqeK`8)4*$bqH;7Q=EL=vu&Tt2'
    '}^F=%BG7cUPmt!`(Cowf5$1V5)-'
    'ZoD1jB(Obv93KdTh^q$l<V4};`rq&puY|?wrMz$trNKLJD4Acx}J5?OFeCGA798`WD>2BN6ZXkO)d<i7SX}m2U=cl{+xqZY}Ja4Y'
    'NpcTcoi*c_bmS}M0K4`SQ3!e=P{Z02wR;%6VYXwtbRx+jHZL=Xdx?FR}78hp+Fw*Q|$a<RGHx0}AsA=uxtJtwrPO>iw(fbq%`fN<'
    '^rTNe(ONeMVVeV0!dcbb14N0ghoHaeb+h)6y*O#cpCx^+D97%Q|9I{vEv<{QXOt;+gSxOT=XuGk!x*OWIqy2Y72h+?!SO_!T5|*F'
    '8-n~K?Hpagz(*`caog<ccg-c(IZx=b<+sP1CU9ENU8C(v6FUEI19eDE6<8oCg(l4j4z}lH;Dvl$4-'
    'h^m$Id7g%J%&)R$|IaZOM08>Q*Klv<cKArIAlY~*C5Z5&75=XMYuL|i*Q!n*_viujtuOwka;;bgzxxVT+i%XcST*I3w}0wz@H@A='
    'Fl@cd55dcpiMj42Vpr0;b{3I8hcCCRQdkrySlShIjl6vU5q=Ou=A0Yo$$qaY_Oyqn>v=JB*baSA_N+GB;IFj$@1@XM=W9(#|aZ}y'
    'B6;<q3fu(5A)cVb%3n++myXSm3!!&n+aBLc@ZgeBf+tjLTd3*$r<zp!{~IKF3(mjX9*vhLOGU7vi)8pT(6!&6Se}JW9zM0+hd%L$'
    '<rLqNeL~s5|If={Ja%+(~kC5L>|>$3|@|BzM+g(etLY7pWyM!m&b>lP=;lKI@)#ud8I58_~>j)P_eJ&wARIXB*`6@YnkT<gN<&=&'
    'WGi^QiGwTY9zoFXRFGUMHpk0ur1`=z+__~nIIvsaSj`48D!Q1LAEj41V>d<KYWsB;K$*?Pxmhany!5^=s~3FaPr)_D4R*j9&}`NY'
    'bkTJzLGe!>8$9p3Y;-|Ik-'
    'R^?EGG7(}s4#`EW;qFu9>^?55ycTiJ)@Q7(AF&*6TjY=M?<gD=KIlWP4kmPgyMizQl?FAr1YMJK^6PGsP&N4%4(F?j=AT|rjzs14'
    '+xS}(RG`6Pupi=P(air%{>|MT4>q1)_x!s353BqIrD7fKL9iC%a?%n(!4mWbq-dJ5guYW$>CL6vUK=>?P%mNX{0BG=nCv=7OI!5n'
    'qWMyp$ICp^y2bqtOHx5~Dy^%lXA<|0RSrF?QU9&J^?mA#I}V{te5WxWhPt9llyI4Ssy#$Ju&YmrKI!kmG-!-'
    '6V|L52)A(`t#tt_sGZmDrhM5lp*ky5Ov4LAN0Nq^f5~1rlOtP;BwVITm+UR0cq4XtE`DIou|#3Ly@XO{d%u8$)`dHotD#wxOM2u?'
    'c+G2Ya?RRN9gMimw;MZewP8<&uf^-'
    '!W+`=kh4q(Rip9i<iq!M%yvSj@<_fbG&$(C<{2%xCwNvaZ`$kg}ctUF@}4uWQAL6A!Pz1ZkIDa(JQ3blh>HK2)G-'
    'Ogup^|(@CkU<Wi7rrzo%Ny)T+1OL>@GqE&~zlbj%lrl~BDljI~N$RH%eT5soJ@U|W8o}w9#wij7z;Fdb?2f|F-'
    '{Os!VE;u^AOIv1E=68+enYT4_ce_r=Ie=TK$r`NhxvXG4O_N!}dNp`okuMK!p3RcKJC&_Nh2~X*uY|P{$q8!@RU9l~2^~8$EBoN0'
    'ddI~Fq0}`Cri;!f@g<uKMN6kS=6({88>pnRP*ayfj6{P{miT!IIlcDsdO1C?O<1!-KC9zMNO1@#pZvT+Ytx4I-'
    'YUUC=j)AjSlyCXRY`YGj~_oj=6{vn>SYuVh%?yQ?rYsj5!7hh>5Tod)ZA!0T2%$h<Gcpjdo#VCP9o6N+J0%dTx&kiTYSt!1;_HW3'
    'JyWm+R7}kRnclKCr@jyKoB`Xb@CVokVjc7KqMN@a=ry0t&u?32%$bp1&2GEfW`W(`Cra*aF`0#cFehz%w3p!@HiEmvj{`u#u<0R='
    'm7zopQCu&mUiC_(?JT&!U^z}ntcZp??>;Y)McS)g3W%v%u%@O;!L1d>y%8J8Jk{jsvpCag%tY5`mQ8PJS_*itk+(DCI@hR!$df3+'
    'ZX=HGmk&6=RO&nQ(Y_TQ)>=Gr2-'
    '5R`%yJ53(QnPNBse^PoW2K&s75XT!>ko?UPy^f)<x#!HfeFpi%5lg6qUkg~#S(Z0^~oI?G9)G+R@zzuARo;+5#emJRL9WI;T7#pI'
    'aB>b{!+^Vbo|w2@yMTFypajJuWSmS+N8jK|u5$t^b&(o9czUqTvJvRLzOO7Wx9B2it<y>Kd&a*6W)k)cpi7DFzWhSZ_5<?ceSiM3'
    '3tdM_cNb}<zR?NTk#{dSj2T5nQJ#@HgO2naU@lY>bWOlesdLye)%r+l3?q%Vlm(@XWaTi&*z-'
    'Ab@79L;QzV|PP(SMqvKcNcZKtpYmEEl=5Tv#|jiBV`+w3#c!~V;UUG4gI6-7@wY&asDbUp1x|}DVs)f#iqRp-'
    'D<>}i<T}(;HCOkL@FfN341DrLp9koZjCy1wB1_)a!W|*EG<}ZeyZRT#s908rH<PvRJ!jHj!S?}rDP=MCf?UV7&>@PKrIO)5=uq$d'
    '!%g}+Ix>=;$h6{ZP)Dt#5I3={s^OPj>WARY44Y{U@ykK)g9Wuuw36UT94IA6X9}Y_r*8^ubHEFHF1W^;joR<<}EA!WRmo@p#Fbe='
    'Rv6j0ch7YV$9CekU6K=dd23rYaT0yQpl3aEm`e96s9c!w9UdU?O6>>wV*K+v6b3{xpLL{cfwMu@OFkoy+)JVOcwT};hGXz2ST)05'
    'Z<<-'
    '{mE&2w0}vDk{e1+*ZYA$Z)4A4x$Jnf?c~nO=_@=sC}B;e&L33aSV>#aT!mv=0XlRi&99Io@|A}m2t_OfZC3f_F0K|JOLS+94$e#}'
    'rwCZEdGWTU7Dz!S0#f0VI)jl~#MF!m_xPv*W|4O-'
    'EWnVXflTo=bq<rvGvjcsokNZRKyS<D#n78Jw38eU<2jGD2Fp2eOHpop`f^EFq2HQpjze+L(v+@Q<<Z81jbQw;w&Z9$CM5^XE=Rf-'
    '<NH`5nofz=)#?GWoTc)1I@=|NIJq_&Rx{}KZW)17GCn$l<|y?lk+uq9p$(=~V2e6rEVPW+y=#CRv|S2wr<3N2nGRN1dF~R6JEzxE'
    'SWU@9Iul6F5t7419^W(-&>1fIPk^qRk&MJ~e)qd=KRb~tgzYGDLAH2H-'
    'u3CrkLgSO{Po+VXmUG%O>`?W=;QwA7BQ~POqdBe@5@wqTIR^3?Vu)yS+1Rg+0b8!_9q99(+=0Ul#a9Bb{ktzDM{7m5U^UL+G`=>T'
    'R<a}u*pFci^`K`PCY>HxrkG)d=h*c%0A^ygr(LdJF117xTydnQMGEM2VtazX9J4tSwpKmFhqI1c~|hZ4ecIq8;=h0^wE#`$r}Rj-'
    'NQ?}-'
    ';G~bNlsmi`|v9qa9OtQVmyXl>%&To_Gmmhbr8udHU#4=OQqcl)8>AMzd~_y#pXyYk&Puo?J=qMZ3&H>`vxI%Xf~xLgjIlpAzH3FW'
    '1;14QadS6#i`Zeg{8L+Aw}1jaxcU+)r?Kgk!D?=mS7133MaKLNGyQDG;lt8e%p?ACaQ+t#xWEVxLb0=t=?S<Hq57hTiX^^`xXv#6'
    'Kc!J;(hO{_1JtN7wod;-'
    'o^Od($B%oX6VXtbx2@bX(pWIsZfZ?<Zu|5GYA8Fakvr%3T^aJhx2$K>!?*5yDLF8{Yxq?M<LKUWj+a!bj(&Lcd7oQ5IAS;&`Z{a7'
    '(u9du2Fn_*YYox!=!sMQHK^z=ktO;DF#ONUQRyGb0)oQM|*S4M_c-}JX`;{9SGm|kLDAwDsya{t}son{;D|-ad!k9<-'
    'uKyfG@^l4j3eMT8V&Z*3iGx0k1VJjL-B$M0TdGgAlG9ur~N|)Z!8GtVLW7c5RfG$XLf4Y0^sjV1-'
    '_zw>lz3ypD4^7F4w<Bb=oBT)L*kqIW~VaW)cRaP!7y2|tq$kTbe$Oq-w=BA=!FtRtRy_^Ic;z?-(T`+oQEcog}0Y`7sJ-'
    'M&74|7D-5j*X1V9QxI|cRDZeGK+q-'
    'zByrGS}?hH8J4T1&~mh|OcNfh?<r^)`t;wD(7Id;vqv%Hg>+URH^Z{ZIZVI|R=c$3*S@`kTA?KgGIMXfL$4fFl~Mc#<(f4%EV+ZK'
    'Rt7l^iWe8n+#5h{c+%*Fn3^zsYXFNx<)yhU|H;9&o-5T{wSt6ajliJA$>#*c7`#prqInb2whisWGQ@DS5jbe!RlFT-'
    'j`m%?YmA4tirv9Dx@W2O+3XjE1_8faVbi1aSpBm#aan)hVtjjL0S`^1R$Z>P11~ou(X1g!ysw)UWe&@^I~E}5&1NpXdDftq$!17`'
    'VC$igZ&{Toy34g>p_0K9XD!(1%}|ObRZSKKZPRPaV0@CpMA$&BE`iYtW;V5j9E8KqlG5R{Vk;zZbAH~*zimT1xwJi8w-GTg-'
    'H_B>?}Ip2)KaT$;#jz%=#B>z-Ccl1>|TtA#GzL%z3lAHYiA-Fm#1!{n-'
    '*|62ea|LaMeX<O!sWXgEDrE9&#)VZC0(>BCIXeAP{ZYr`X9hVcX5igQv4Xjke&NRHq>!WfV`343$da#zxx;Nth~y3IZF;HG-'
    'X%TA>ecR^Nj5=z+V^r`)!q{i^N<2{fBm8NXWr?c>8sd3@-1pI=ka8+|YGN+I#ZxYPGWy-Ha0y%+1TOqOc4F8bb!@m+t;<Mf_+Sg!'
    'eAyIe3i7wNR(Sf=NLiVm48VI7y9@tjeDWa?g>uPd>KMp}oIsZ+)#xb`}ffP_ElFwyG72^W$e`lLh_P{J4n?P^EGKo@$Eiibp$W$('
    '6DZWbp%j>=C?s<_gDjO5(B(0SX2_TiX?r5~NBV#NL4Qqg38YVGBhuWg)OhFkS1y|K%j^kUrEJ;<=uKX|dezNR0wdS2yebhVmv^0Z'
    'Qaa<RS@b+`bNBVt^x4upYam02}TWw%rhmZnl1_9_e((p^)DCgo<6mH4;YmQk2>O%6>c2ARl-'
    'e@+r1BUXuvsbSJlJ&hgnSz}hRfZ1S%LXgEh#wc6D+=UF;>`lm-YDAu;q~R<vjv$|~lbCl-'
    'qqps7FO7!7DJ_U*U~M;p<hy)VFFLbZdloz{w-JuE-EnaAD`9Xv*s~zsY`JOSVm#Kh04v~y+2mA!FjFEJmh%*rHwI1Wq3dL`&}=vQ'
    'r4}UegG_-`3AxLI?E)9UtfkspWbP&PX!#_GXy6zOh;Jv*dd)6`)#)b$I`J<QP&Ugk;dDfjQ^D1fM55V69cn(Xyh-'
    '!IrakQ*xZ;n=a!B|kznWW`Mff@0-'
    '`{=v@)7+f{1iW$Z~5E9%Qy201<FqFyz!nXx<JcW>R0Q|_*jlRy+&CKk>BiZ&~_nCYLCa|s)H6@1`{ctU%BX4`y0r~Xs^VCZePBz+'
    'EArclZ%{NOZMkwT;gvdO>Vbdzc8Qi&;h!#ZdX$iQmyk0YmvS5&WV$b<7%-'
    'BF&Br`lFl~hY)jJW>+EYdNj%F{Vv}lTf+Bkn&QK`Z;HX=TT-'
    'j)mZTDeX1~Sw{oPc<ahUNT*xx3!BpZ$P8mi7WI<FtH3%=>fRIbF#`UY>d~8%@9Q^2sh|y++#+PrW8wKi924Z?@8`>w)9ss(YCCJ@'
    '4%=AwrYm%5tj3huDQVlRUyD#{`B-FIJE&4~=-{%C--qh8nZ42|N6DUBW&FOO8XyNvMVGtx!^3$l&G8Nn(N~UbD77y?L_cteYnryu'
    '7)+%3N>T(cVI?gFf4-'
    '3PiZ2%=PC|etaH4yivB&thD<(b4U^%m;3!+tp|lGJ*>sdFb$daigbZlF5<eX0ug61tuGPI%vZyNwf@jm)Tv<EslF*k9rkSn-pOG1'
    'r3=@K)R_y!;Dvfu!86L&dX{JVq+STZp+sAlyvrd3?H4NCQZJ=PNY0AWH<734wc?S^x_F}CV-'
    '$*UHJWtOmiEe5@=^IpIZSS9s>A2<^vl<=5>q2)yDeglyj)XpG436%WFV}RV!oQ+@>65E_G@}dSF4v>U{>VoFV>0nj^pVC^0;2R<Q'
    'gUK7AW<+#02Ddi!+7zVST0IQK@Rxe`}Cxw7@Mx%)+ESpg@^x)hXFbNlS`?D-^Q}I`jukPW7asuFPmtY&y6tRxH`&)a2L@R^OU9-'
    'NN3vp6nFPMyFAnL#QRl@X@lNE6t8AJK9^*CBLGBy~8@{YEWdk6*$+QKibRWLwQO+*{yBFv-'
    'u>yY9t=5dv$4<&5AJXXnpr_;}Dd$(h6O!HZerMJZSaR`lcicINUYAO34n(H9*Ie>tzkXC&z_^ebWkSj&cCby|c+4dyW9m<caMzR!'
    '3Z+CzDNaEaaPnVLQmV)Fv<PbZnDFd7>k7ZRt0o+YVI#M=PHxVdGYMZqZjt>{}12<W+Q-S)3Jmg_APe+BYG@+RoYbwhir8ymbDkR-'
    'QO)!#4%+AHUvx&)@p{OhhN}`~(~4xG*i(U|)>82NatXt&fZK*wwSOb~)vJF&-`Z630o)5TCj1XlPnGJ}l?G$lSdI-KKMm9CXA%v1'
    'CI}zG?{FweG1JsN$*_B!uf2z{e)E6axmXzn$zBs-'
    '{L3egm3yf+*XOC^kjtvOP<^^{jJWrU;LLPSV4S!tGhpVl#+u+tL29rw0*k9a(=vGnzi%J-'
    '$O*Jj>S9n0kyAl6$f4#I{cCqGh4#SMy|osGCk)8<wk0QnaGs`D%Tq&N}aFQhzzFSF69ltO)wd2a-'
    'o&kCW1J(0RBp*Yv3YlPAwMH6!tMq*!vu;<0;ZE|x%zO>?DH)|;H{s(7(%b1UM-'
    'a!n`Iih0l8yCeYua+4hy*R>ehX6t$Zhb`J@k?kzbw!=qxMw~6ITzsN8^J1}WTiP#jdl1zS<TrmqH`DSd=0mX7o}ZO$^2NGyEV;L%'
    '7~<caOMbD=8mG*>b81}!+pS!`y;|R>xe9x{zxudbJ2K*O_i{8aJ1(rBs_b3X^GXwHoq>ia+zxXsh8uO4AnBOnN*O{d#-'
    '=X2DxNrK`KYP#7YcXRf4fY$g#SWxt2L!jleoZ0xTGy11Wo@$xjG}<3a58j;UwW(3P{!lHwXB({p<#KI4VUC1aM1k`^#hfcHa(R+^'
    'slncchMt%wjF*XghSP1#v|_VLG^GUy^+~sQo$*Ze|@+JS%FkI?i=odP3Q@*lmGWb2ccBGC)=xv}A%d3YlP4(f}DlZ$Vf)75SDdn-'
    '{NUe>*Uj8hi`#(FfzfG<h@auTHH(l3z!I?x4r1K7nOEOGnd^d`=OsS@^ac?S^wa%EFD0!{yJdz<Hc0aR|<2c)54@V%#efgeyV?uh'
    'wJ9aUL~37RtLv<7}X^nNL*yJ86BlGP-=0RkSg<Ne0krCCfa@4%(0a1#71egZN?_OVO?kWfYhrRGpV1v=40sOgTV--sLX{WoX>XZ-'
    '#Hc?i%)jy_ML7>Nf}p$w$`0w?b%YQUU#`iV&YB;Kw>!Y3y5_;CtJS_R7>B9@~Z<O}L@njn7{{e{4@rk541I?bc#Z@N2al^N}eVH4'
    'Ie6cu~V(G#+f4^lrIH>|&f>dR^Ult)58BMPxWr4AyZd6M5fpIlt~IIu6vBkbB9bd2iv?@)}8Kr6Vm*Y4WfZ>k4LXe2zjvO=V%~R)'
    'X$&lGwEs_5jtpVtx08g<*ysLjzOAgXStnj_01HO_K`Zlgh`m9M+oPuCBYb?P$M*0Uhn!Ag#i`Aus)uzW#Lg(r{F~-'
    'r9c^SE|V3fhsa#zqHbQb+H~4B9Rb(`M?>C?-4JUsod?bT%Gv3tmfxt&6(gZPLBttjnVTIc<B-'
    ')J8hiIKIW*m)}>XC5;{{a5y2)R=$6<PR<WT-4&+hoy(y+o>e-'
    'N(lq4`P5nG@{s(}I$!KdhwPo^QKF7F1D?kn(gR=yihi@CkAbMb<0TiSnVeKa=~ghja<8h-'
    'rw<<O<Ix3n_I{MEX1l(`T{_KWWL&HUbjMbnscT&}%7#Q@8Aelx$7Ut2l$CyFGO^{Se|l%UXcw`QDX$fAjE@YQdvSOUr`nO#Ew+Nw'
    '}N7(=q0f&#s?-jmI>>$y-'
    '}(F)1XiF>zJoRoI@mu^GllTzLxyM$RU(7~3RlVO)~^0j2)m0r6oQt85NrvgI;&I_TP(>ZZ)rPR4;OS`=@92^D3^6-'
    'qBN;iV*pVCv$-~Rg75!z&;HQUF?EF=43+{v<?R*)^y?2Gjcc78g1ZCI_2Uc(h-(O2sm=;WVCoI5U8OVnvG;XQWmymNS-bzfiBGdM'
    'd>Sj1OLs4O1DqRYvq5?o^WP+9yog_L7RULcG<W!tQWoI<c2JlK;2JLM^lxd`QTDF)MGP@%yt`zXS9<vGmJU>zqkPo_b6d(uECW{z'
    'IZ+Iel+rY-H2`#Y%EDZidz%q>-(+?8+ok_zVFwvMNOWf^LiJ-Zw8V6<3hGMJ8xr?6(2a<r@w_GUjcMLjNpcQ#&DpKm+8+}1CI>qx'
    'oQoNWMsX|7yy4be0Ksfk%xXR#(xaXpz}sO9FXM3k*k_Dlr=xRcOp&=*q*`Bq#OI`6dG6UbI4m?=!iL0}Q=bmF-'
    'i`{7T?cSW6e>*GA%wQWng(R-|_1cfX3a7z=<1-'
    ';+OF6_F?h2nw}zF7Cxijf?nE5%|L^LzK9=SjkAT>hPL#vYc1??>x<P%C75+OjdO*MxV;FFRw^)SS+q66WkDo4>5*8EtvFB<5yg^I'
    'e6rlM6|;v3z9coUJzdi1$rodP>cj+*&h6T(;4??@4-p(UxGj+ZM7=Sb1_2#^`eC-gPpNK@PcOrbAY(^C$UY9Vl*<rpz@<w(V$l9j'
    'Jk$f?-j96*ts5`LAEw=TR{XxB6la%Q8L}<IZ3i<lp63`C>iTdByS#%h$~p>znt~xq}nmIV@MF(5$GHglYELYlrYeWo1~-WrvF4j-'
    '^tM5)sEH!Jy6>l>oS5@Pgrzn*|+H$W3Aaz!JN>N(ge8L4}h94?>fl*tW`YjufA*kmV-Zp%z`Ut?1lWb`@w^6BdTJ<P`ldXXHnUG{'
    '^9^9qn$t@<&^*{B7y)-v8CTN_KA3{EKU<1_v|^01U1Oc3!N<($=ctx;UHN&&F5mEH8^@@kTk$%fH4v!CNw1m-'
    'ATI<ld`EhNIQS<CuXmGp1a952ZU>#Oq==z9eDOiK>gjzK2T3+G{!qxv>TmFNm)8Qmt*xR`L0bU6aT&HgWm6<~B)f>CE+$gh~V(hJ'
    '~1fcvT#-Wk<V_dsMA6=;+`Z3We|g`elfN{U`UyZw!Qa#rclLy_1nCELVBGT91L(SsUF-L0X*N40-'
    'U=>)m0wK6!cB_4?`OAc5X=F6_9RUmUY|6N**hTw{_jLaHRr#sHbv3f5q%cw-^b<O7(dDu||3Y!qX+=B&2o>TNG_l5me&+-'
    'k{?s)zR6Fku5Dae+9#G?5))k7sG$qvj1PW4NNvn|8E+#;QB2TA-264Iy}t9ieU2To#vGBQM6C<(Ux7vf}-'
    '#^{txA`^li;VYPa}WLA`cU#)NKHu^BR{~4F7@%yq|C(N`P*zr`Ia9mzp7)v0VsiOqGp2gcHaV((^+Vg=8CrB}=WPya`ZP5HnzKW;'
    'HsY5B%oCDreB%BlqZ(DaEqm8MgC{ei9fQ#qLrVDl=P9|6Q@%M4Y{5QQC(77G+nvYHU+39=XsKj4D5-'
    'xB<9nN3sc%1}Wi!oPjlIXxil9dB>5xW=Tkwo#BJX%UzP4~I)a%$~1c-'
    'rLXaaw)p>ALvRp>5g{MH0cK;7oV&qo!WT^^iEZl2xBq!o9#HHVJM8x#DP2*IZE_Bzw-'
    'N??~NXvQ3<Mj74@}O3T>@F~{m_QST;nwZ!Sg5%WovmO3XK4d8rA)V2-'
    'nO*|hh(F!{M_Lll0zC3<=xQwRQ3R&w1z1XF?#hIAw#(N_$u&l}XYCWbzFL4bmcRP*7cUex3eyYo<%e7(-'
    'w>&9|X7!uafSq`9d8FM{AxCg}ko(khT9V3S+n{-'
    '7r@77UiG0mfATBtL=(+0^r1)HGEVo`Tos_2%N^0f(l5;{&Ym2rKbcr)fEiM+QP+ZO-'
    '`Kd6c<+F6|Ax5&J0^U@XbJLD?*Kv40C@M0@`rc6Q;@9->`SByXc0%|;ZeSCVgJZu)MlZ&lNVXDwE{46Y)>(7myti<j-'
    'L5oZy;|P|=>aFV%;R!ZrwroC*f%r14c5U>lU8Imba~F*vFkZoqt*SKkx*+ra;m0cC<SzOg#?98e1QdY@@%)5a*;J_t&%&dEGv_(S'
    '~22{34uc>H9(1p*e4g|w`&A;p2MW^fx=lsE20Gwz+6>KZ`;pqEC)C$5M+^VN$Y;Va!Gej#{dn&{8n^=-'
    '2Px#CrvHl`C@#(Qk{+?9#(59=#}cwFslvSr=*XxoPnNS9ue{+02o&DX;H{o2xBdw1q$-'
    'enh0Kd@#GMTTqQU*wpU^QIi=*Pkyts@oON<A2-U=MK#a8~IWwvR*p^MDs%?NKVG?f%i9^FkSp2l{!Njv-'
    'V4doL7!l_s)7y5m8^&~0B*cK8z~;7K++Xkzh~?8;?ti!#cV@IqTn6#QcuWCEye2HW<k9#RZj+ff&0)2A@GQ3`+Sv#m@%*!~Z^Lp1'
    '<kCx(fVrsXg`8O8E`(lVuvzCghTg2t8c-+ky(Sh!wBnD1+_ME&>8!bpl?s!*I?FlXY-'
    '~a}gz)5sSs+%lK)Ykd%F{Muchck;FNlnEeFMC0KYR7BF~p-'
    '&(7pDp+z^b*og8%S`T3I5f~^fqu*_3O+s?}*P1P*kC5^^I)sMWQ?!!}UpP`j_-dMakVq@6_t90HpmY<#pPR{YU3yx5#5mzE~xfBy'
    '}Xi%e0O-?Oq6C~9XY-'
    '25MsIDYskK|J(LWv2(S&BZ?iwl&3>x4cwhHP2R2OZR;y1j`Lg7#occ(gFflZ5yz$#G|eNY4cVw(V$V9@^QXd96ThY|XnF=sq?47~'
    'g=qtq4m((8Y_@(Y8~+-'
    'UV2`1%9<2Qu`odSBkeU*7uxr43oRsak+YX?Quo?dd8t4P8y)(X=F1`Y&Cfx14*P;BUGD{DcTfkY>8IFJ}u`Lcbmi&^?*Ha??Jgzc'
    'BOYV0rFXM-x_(_a`rm>)pT*~%;b9W&`Pn!LJR_%$wiX<ZsJLehw^=%<9yi6w(acoz3%Wu65F83h}!}1-'
    'S;o)K?w9kLvtg7?I_H$kenWkJIQlUotj1Ve6dbj8_cY?VSS<;F4vu0jPJ4`aVh~YE>{UOEQ46s_0+vnn7_8BnCFf-'
    '2u6*>d9CIk0b%g2296n6bu2n@i8*4T$eAS;?gI8C6g#O{Wj3Xpl%6Kzn&(=5&g>=nG(jF*a%g%qSq>Sm6<~?oRCddrHZ>|bBJbV2'
    'Eos|^c1~|}bhH>N8hOZX3dawhfrbkv`sD0Z8IOSLde{5MQ0P$L<uMc&>#<Ch^|T^`I~w0*EG2fG4vWy`s`}PqIo53cDx$&31u^P%'
    '@%)B3axsM@!b-'
    '8I?vJU?%R>W6h_ewU$qpN#&YS5H6DAHu&VVlKR5NlrYyN7_Bu58y;R%STk&USu$S(96O;L%@oP3+fc$^gkOMoeKMe_sm{{KxI+Fg'
    'vr_ONtb<l$cARuKI1(^E@hUB^Zd>t&~g2WlyC8Mqk2v9?0+D>6ZNjFZ#y{3n_vtY8{UgTHQB&_RPB0bFU$wO+c-'
    'I+f73B5v70F$^`d+(M6)vvp7h?P}C19F<$CC&}0b>&2V2s*1VjO3kh5h+7}MH!7!F3r1fij2VJ+;jF7*y@}FsdGqU|O*`5h^d2pI'
    'miS<77QYdsKDS}HecThemHVQLac|QC!I~oVXgxLu6&<c5#z*5(x%t_EjbF`JjZ@uy2nHr4pW|{a%F&7u$L`2V2-^@tHVtfSs-eyy'
    'xb98%;(T)rUF$kriCRTil1YguoK!pMQ;X!WMgdY4%G4bpgPa#WR>;Bms5N0Qsparv_VtYMFr;z>bfw6#Z9jX*BWqxNDBY~2Z<wZe'
    'Gw^+Qetdc!TNk!!am1A#{&=K^Kdy{Nz8DWBtejtQxufw|g%_?!PTQH*op)1}tYI}*sCDEdjB66cQpR9eo)8@g5e(@RG9Av^!8mJb'
    'un~Ie+V7jY-Uv&qYw4tpBX0|pC~v8wh+U(QTkNJpIZMR*$r)iB<(MZyt}t~xYs{ijP+)tNuG+Sxy<-'
    ';LLA}bT#Ywj`X7Tx@mjCi!hOPybtF#+ypGO6erRwL=y0`DhVOW{>@@js|{5U(+q#KuO87lz|`^A*i#X9K`8e8(;n}l?|I+hBSdl-'
    'mk2O6q~*d+Ok-sy<&8Kj}t;Cl;3<+0?*msM&K;N~KsUMw!;ie9`?!)oM-D%NC3+HhDpVTY4i_>(FFq?U6jm3&T^N-'
    '0h?Ya$1<ja=+x`UKJp=ByTe;9=MTULkthj`nhCe>DFr2eq*H+lhL|?OwVWY~1RN*9x%Wkpe6q<;h*1({{1G_4SxRpYFA-XSh#YIV'
    '^;vt~lk3^*u@KrxR4i<*Iz8U7qeD5$@D8N7XK#a0%6qnFqzWcFz(4$Ls~P8vBK8C0-'
    'DwEp(FQUu+zOU5bawR{lQ7aey^Za>XS+sfNQA4=5)@<4i1vh$9u^f|M}$kW*_0kz1amuk@~*PAcL6qY?JiWS4Cl+M9qLW?&vFsU%'
    '`!ZwSaQ<x9H1e;m|xoDgf+*jGqlxy#{V+&c-G305W{kJdM|F-'
    '`Kh!)kS?i*VQFnJ$CzJyi@a6}}mkYdD7G9wi8uF5ve<5o63$f?k(b*{#&A6}KB8lq_eAM8zBpbrg@IbyqzKly!WQ0dK1}Lc@av@4'
    '$8}?YA2P(VK~_2LXmeq_K#5WK~gWDI_5pMN{FXlbtweH;y<t1KM&P%1;>PcT3y$v%mA<pn|1@lX^<u4(opTDcxNh^wy4t=~VCQ0*'
    '_gZ|3*yvu%awI8jnQFaitI?&I(cXrO>Qd&QaUhG?%|unFT3evvP7kti`k@-'
    '|pnQY7<wiMOZ++0csAp=(t7W8wmT)s%_jb+mncO3$X~j2M6633@sWJs<+v5u4$N2$|eL`rs^DV=)^jMSQ~j_lv>Z*l{Rf?Z^NNIT'
    'vKVi5QE#%gnzk{pKlD5x5?^UlnItvZx6)Cfru7CdojMHjDnraC>vI*(Xm@;HXM!b0yv{Q?3)0NE?4OTg_WYLIJ;qDurSr;kjQvWr'
    '<-Q9YS6NU)|wYm?Yj-Z)GG9ieKryxyHHVeN=mBWeCiI_6I9Kc(r-'
    '7crFY+~gAxEL8KkCD$e_1U0SQ{xn=dRAxel^tjd{?EIm;jvd*1D^X+t~Rumw7LKa6lw1pC{=zui65QSEMPk3(Fk?}!J=J8TS-'
    'H2AM%;RD6PN?Ew9b2r+KwJFWCcj;FW+EX+OR40_0ewDVy*g{B-'
    'W5*7m3sqFfNI3$G?X2U6oRCISqddjzRVhB!>Ii!&oYBBZz5lM*o`nzVEae0`{8e7syV@x`(D_cSatc08fa}fzt^>``BVIKdZracO'
    'X2WolKC>M&KsN&1e@nmIr-%Bn+~2iP1i*Yk+*;&etXrN`J{tG-4m-'
    'EfIy@K;wi<?I&7IM9OuU1_a)OIygI~Sov)<2!UuCzTAf}uhii?$>6jK82x@*ZpDuF7Lm>XjgM{JwK#oSDfTC+x_3Y|Ww)i4CD`zo'
    'cP5XbCWHWtL;WwOz>Ucn?Ck8Y-e5Xa$BXWTnUtfV?&S7VDe?PoWH<IxD%yXgE4iB!Hp_}kO->#(%V5O#Js!!_D=@@l_as5RP-'
    '%{Aqf0ZY?ijXNc5?OKz=SUobi$KvT|)9X&*tW!lgg1QtFQYS%@uL4woYcJjtvgPKZlQ_`HbDUctQ;c^+I{NUW>S#yBW3@2`Ta6(J'
    '2`C2FGpR7MK+6|M>H?>=m1lJ+LG%pX7&pIU+P0zn_~pYc7;Y*We#LM5d_RitYzFTrUcOYpxW83tWhU`#B=N4<4J)IR0FMfBEstB7'
    'v3v+K-'
    'OG5bZ%5dCP0cm3C97AJu&NIkS68bI+)b%5wA6Fcwp3x)jT#h}BtA)C&YHC1tF6{{!>wjxRLTOnD_py2p|V6Lr8z&JBYsw6A?px1y'
    ')&QRCvDo$-o_*gaI{Lx=^)zMNjiTo`D1;$v-@=J{K^zxKO5q^wX@Kz^cA|JU4?NuJwDnF`dXxAZJn9qrR;C!Y3-'
    'G#RmKP6HrckILwJOb6=bH|a<l=1O(6-DtdKDECIMzHCP-LpC_=aSB-r*AoxDR$#zt@<_h?j>y6Yen$Z|pi`9$P9rt{9mGPN^Yt(-'
    ';_=sMcnwxiv+JsRx-c@y}C(o~Au&-'
    'dR)*lwS6=9haJF2<diD!V37X=ehJ`=U``zs%<^#_6G8W~ag`u{X<^=U}FX7Z^JosxmIGW~#^|#X8l#hvX8tQoPC{27=mqhC;n)3w'
    'tl>gSm(k>Rn<!L36XcpLB23C4A1RCC~&9oO%`KW`lLzgeLK2Fj%wmY1W2xmZpxx0^UfRe|6crZA1J0?qU26&8xTNcfUTh=eJbVRt'
    '&GH#?3Y3Hs+~txgKk@9pTEne96VrE3Q56oN+P5%+sG+!qkZlpDM)9OE#*Z%2E7D)8Zm=EKO4~R)>s><Bd5vt(k6u+Q<^!354Z4Oi'
    'd|9Z%uM%soBL+LrOYqJ0;hWE43Idkhu#_Z$^LvjcBH37u{LeDHCiQN{(lDy<0Z48?)$+Vis)}qM#eX?32W|Py5I+(psYr;eoPf_I'
    '|naYBV0yx&d5Kz#5Hj=K)VACJd`Jrr_d=0@n01(5}|0kll5y2KPkSG>Khx=w6DH<$+~+609|xJO|l{@7cGG)#^OqnnLdq@Uf0FgO'
    'ety5QW%6_pxElks%2_swc~-'
    '0cQjWy0rtDW?Jqim1+b>MleEi%Dinqd$Uu9j%Jq)T&lir3BK*2wx@j_R{*sl)H)jX;+MkmD5TMN>~1LH%G4&DRz&TS_Q0^5UB)m?'
    'F8lF!{??U5S9e3!_u5p&-PF*XOD5@XQS@8{o`~JJ<YLK&Txl742^F+G2Yf23!4XbUud{L}c+;&HmTEf-RqX^^O@)@obvbiVlby~O'
    '^GSC@0SA2?m?x^X?Ps_1Jvu}s>Zm4w+d}X2Pha+uWn3P$Ytig)C$!7W`-'
    'AOJ_r6&bf~KQ4O)KM5V0xhqFcsSXf33BVYKSRhi3a2?qAw|8^V$$xFtddCl{j>3Y$I+u+`9m=%^3|fdC==g6&YEgM=d*KYG~yRg}'
    'ZZZCOQ+*>a;(-'
    'J}xm#uXD{wl2^eHal9IPv~4@P5o_&Xx@=6iu@u$wFArtB3fkNOyb|BW1M#g;p+(4!wquo4)~_5b9?fA{fZ>^4@U-'
    ')qW)opL!dq7JLaI<u<&1UWuLDPHT(L#`YM19S`UEa%m8PXi1Q3G`B^2M=G^68-J*mgYRh>}+L0l1I?=3+|Hfxyauo}$XiLV!LH-q'
    'g-^UAD*@T8&cl~C-a4ebXmAMV_zaiZo80rz{q``(^+5@qnq^}-k9-Vxrg>~Jr}gHs1r#+$m?c+;KmjmtvM7-'
    'u51Je@Xf#c#~hRLyhij^*LCiCS$a@03igLX$H|^s56?gA-'
    'p{B?hj+15`i{J%`TuG_MO3n8c6f(qiE3DvPsk;)~^}1EX6>T?Zpfh%$*kJjv}+FafNa&kNnQp`CH=kcBxI=7#aiz8&=Ln}FmTFIP'
    '5Pj5|xG<Y`>4of?hDZiVDoSQdG{7>~~S1-sH2ILlCJ2it_+!>@-'
    'e1oknhl1>JMT#GBgL?zF}se;GEO+{l;)(U*|He@iy%Ofi8IXQRI#jZ)d_UwZAwqTpEL-FpxiHoy7^&-x%JNZe%w7-'
    '`}HTpA>%qqeeJ;dvRj4eCbi(Y?JU{Zqmn`+em{&OymU%os(>~y`fR_j3VKrbK)Cs}R=yjYKAslXzwZ1-'
    'Y4I`r4Wavie=n6>wknMm^>>oDJWwo3d-'
    '(SBWyD%O@l30QK3l&nA{>&$r)KFuoTZnDJ4T|SnAQMh+y(@)~i5^?vO<W1x_5$Eo0!c+x0oTEpjj{`AC(*g~q;7-'
    '!ekrPZ6pE=AW+qZ3LACRMbs)vBA!non4+7Z5gxktq?e&SECtv3+FtE`kkUaWiD^i_OfSwZL3JgHdnvtB!0uFfY4(JXgPT&(YPR@y'
    '5t@yX+Q&EW^POsF03?A5iKWm>PnI)m@(^0x|I?zXEYrMM?55w)||Vi)pkbdnjxCNRz=Lq%~cg-T-'
    ';mL(loc#?iQ=~Yn64I)BeoyY{qx|}Qd8jIda_ZsZ9EfCyrz@AcYr5wwXn~PCy+tBWy*!iPDu}*}%A>G*T&p&<X?V+@N=`2LM$gOc'
    'UJY=gP<%;MAz`+c(TbZ2V>9^L8T`z48)fu758RZX-Gi4M+YN#jwOIlh~O7jUC)(|CRPCj&ba*=zJ0~76OaWLgr8?+jo>lKrb#!>?'
    'bwHM0V3$&gIyq(ra+Ce+yj67Bl$m$i`)$s03JK8(E+xWxN2ifxtm23QUM5^5=Jh|ML6K8!n8$)1>uz1CLF&;q`&IWt_N;MXy3}Ih'
    'cBpAPZUu0&g?|Kb1apJ>ruFkG^5jELhy2Jv3<jW>BHXKrjtfd(okT^@Q8>??XF4c%NWtH0y)SfhJP#n1%3NCGNzT{+M554w)@{ZX'
    'fS9R%A%m(iVt<H10?~Q~3JomEOHnbbEM<t&zSW7oF=jgA`FLgw%|Kv9|4y_Fi@^-&uEGbZyyN52;W1R!~t6JRc#rQT(*cdmt-x-'
    '&yLG^MAKDcS&mO2tMnN;jmoO3SuoKPbCTx3TMx(-YbzhYu#r}(Hnn@owQYJQ1o7mkR`z`<!>pwPy{`2Ao1KR<tSGy'
)


def captured_rows():
    raw = zlib.decompress(base64.b85decode(CAPTURED_ROWS_B85))
    assert hashlib.sha256(raw).hexdigest() == CAPTURE_MINIMAL_SHA256
    return json.loads(raw)


def with_section(data, name, payload, *, flags=0, section_type=1):
    """Add one section without using objcopy or executing input bytes."""
    data = bytearray(data)
    shoff = struct.unpack_from('<Q', data, 40)[0]
    shnum, shstr = struct.unpack_from('<HH', data, 60)
    sections = [list(struct.unpack_from('<IIQQQQIIQQ', data, shoff + index * 64))
                for index in range(shnum)]
    names = bytes(data[sections[shstr][4]:sections[shstr][4] + sections[shstr][5]])
    name_offset = len(names)
    names += name.encode() + b'\x00'
    payload_offset = len(data)
    data.extend(payload)
    sections[shstr][4:6] = [len(data), len(names)]
    data.extend(names)
    sections.append([name_offset, section_type, flags, 0, payload_offset, len(payload), 0, 0, 1, 0])
    struct.pack_into('<Q', data, 40, len(data))
    struct.pack_into('<H', data, 60, len(sections))
    for section in sections:
        data.extend(struct.pack('<IIQQQQIIQQ', *section))
    return bytes(data)


def linked(filename='supp.debug', alt_id=ALT_ID, *, payload=None, build_id=BUILD_ID):
    if payload is None:
        payload = filename.encode() + b'\x00' + bytes.fromhex(alt_id)
    return with_section(fixture(build_id=build_id), '.gnu_debugaltlink', payload)


def relocatable_debug(build_id=ALT_ID):
    data = fixture(build_id=build_id)
    # PT_NOTE's offset is at +8 and file size at +32.
    offset = struct.unpack_from('<Q', data, 128)[0]
    size = struct.unpack_from('<Q', data, 152)[0]
    data = bytearray(with_section(data, '.note.gnu.build-id', data[offset:offset + size], section_type=7))
    struct.pack_into('<H', data, 16, 1)
    struct.pack_into('<Q', data, 32, 0)
    struct.pack_into('<HH', data, 54, 0, 0)
    return bytes(data)


class DeferredIdentityContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='deferred-identity-')
        self.root = Path(self.temporary.name)
        self.binary = self.root / 'module.so'
        self.binary.write_bytes(fixture())
        self.managers = []

    def tearDown(self):
        for manager in self.managers:
            manager.close()
        self.temporary.cleanup()

    def manager(self):
        result = BoundModules.__new__(BoundModules)
        result.held, result.records, result.deferred = {}, {}, {}
        result.files, result.unique_inputs, result.endpoint_debug = {}, {}, {}
        result.debug_selections, result.indirect_debug = {}, {}
        result.transitions = []
        result.evidence = self.root / ('evidence-' + str(len(self.managers)))
        result.evidence.mkdir()
        result.cap_check = lambda **_: None
        self.managers.append(result)
        return result

    def capture(self, manager, path=None):
        path = self.binary if path is None else path
        row = manager.capture_file(str(path), None, time.monotonic() + 10, manager.cap_check)
        row['loadBias'] = 0
        manager.records[str(path)] = row
        return row

    def profile(self, path=None, pcs=(0x1110,), counters=None):
        path = str(self.binary if path is None else path)
        return {'maps': [dict(start=0x1000, end=0x2000, offset=0, inode=1,
                             path=path, permissions='r-xp')],
                'buckets': [{'stack': [pc], 'counters': counters or [1, 7, 2, 19]} for pc in pcs]}

    def test_capture_is_identity_only_even_with_normal_altlink(self):
        self.binary.write_bytes(linked())
        manager = self.manager()
        with patch.object(manager, 'seal_debug_selection', side_effect=AssertionError('startup external access')):
            row = self.capture(manager)
        self.assertEqual(row['gnuDebugaltlink'], {'filename': 'supp.debug', 'buildId': ALT_ID})
        self.assertEqual(row['externalDebugResolution']['state'], 'deferred')
        self.assertEqual(set(manager.files), {str(self.binary)})
        self.assertEqual(manager.debug_selections, {})
        self.assertEqual(manager.indirect_debug, {})
        self.assertEqual(row['sha256'], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertEqual(row['inode'], self.binary.stat().st_ino)
        self.assertTrue(row['ptLoad'])

    def test_missing_supplementary_is_absent_without_invented_symbol_capability(self):
        self.binary.write_bytes(linked())
        manager = self.manager()
        row = self.capture(manager)
        result = manager.prepare_symbols([self.profile()], time.monotonic() + 10)
        self.assertEqual(row['externalDebugResolution']['supplementary'][0],
                         {'path': str(self.root / 'supp.debug'), 'state': 'absent',
                          'kind': 'gnu-debugaltlink', 'expectedBuildId': ALT_ID})
        self.assertEqual(row['externalDebugResolution']['supplementary'][1],
                         {'path': '/usr/lib/debug/.build-id/99/' + '99' * 19 + '.debug', 'state': 'absent',
                          'kind': 'gnu-debugaltlink-build-id', 'expectedBuildId': ALT_ID})
        self.assertEqual(row['externalDebugResolution']['dwarfFunctionAttribution'], 'unknown-not-used')
        self.assertEqual(result['selectedModulePaths'], [str(self.binary)])
        self.assertEqual(row['metadataProof']['perPcCandidates'][0]['exactRangeSymbolCandidates'],
                         ['alias', 'outer', 'overlap'])
        evidence = json.loads((manager.evidence / 'debug-inputs.json').read_text())
        self.assertFalse(evidence['allPossibleBinutilsExternalReadsProven'])
        self.assertTrue(evidence['noDebugDownloads'])

    def test_only_actual_pc_modules_resolve_including_zero_live_history(self):
        unused = self.root / 'unused.so'
        unused.write_bytes(linked(filename='/unapproved/escape.debug'))
        self.binary.write_bytes(linked())
        manager = self.manager()
        self.capture(manager)
        unused_row = self.capture(manager, unused)
        result = manager.prepare_symbols([self.profile(counters=[0, 0, 5, 23])], time.monotonic() + 10)
        self.assertEqual(result['selectedModulePaths'], [str(self.binary)])
        self.assertEqual(result['unobservedModulePaths'], [str(unused)])
        self.assertNotIn(str(unused), manager.indirect_debug)
        self.assertEqual(unused_row['externalDebugResolution']['state'], 'deferred')
        self.assertEqual(unused_row['dynsym'], [])

    def test_no_actual_pc_never_resolves_any_external_debug(self):
        self.binary.write_bytes(linked(filename='/unapproved/escape.debug'))
        manager = self.manager()
        self.capture(manager)
        result = manager.prepare_symbols([{'maps': [], 'buckets': []}], time.monotonic() + 10)
        self.assertEqual(result['selectedModulePaths'], [])
        self.assertEqual(manager.indirect_debug, {})
        self.assertEqual(list(manager.evidence.glob('*-endpoint-symbols.json')), [])

    def test_exact_section_inventory_raw_bytes_and_capability_unknowns(self):
        data = with_section(linked(), '.debug_sup', b'\x05\x00\x00supp\x00checksum')
        data = with_section(data, '.debug_info.dwo', b'opaque', flags=0x800)
        data = with_section(data, '.zdebug_info', b'ZLIBopaque')
        row = elf_metadata(data)
        sections = {item['name']: item for item in row['sectionInventory']}
        self.assertEqual(sections['.debug_info.dwo']['flags'], 0x800)
        self.assertEqual(row['debugCapabilities']['splitDwarfSections'], ['.debug_info.dwo'])
        self.assertEqual(row['debugCapabilities']['compressedSections'], ['.debug_info.dwo', '.zdebug_info'])
        self.assertEqual(row['debugCapabilities']['splitDwarfAttributes'], 'unknown-not-scanned')
        self.assertEqual(row['debugCapabilities']['dwarfInterpretation'], 'unknown-not-used-for-trusted-functions')
        for name, proof in row['debugLinkPayloads'].items():
            payload = data[proof['offset']:proof['offset'] + proof['bytes']]
            self.assertEqual(proof['rawHex'], payload.hex())
            self.assertEqual(proof['sha256'], hashlib.sha256(payload).hexdigest())
            self.assertIn(name, sections)

    def test_truncated_missing_nul_empty_or_oversized_altlink_fails(self):
        for payload in (b'', b'filename-without-nul', b'\x00' + bytes(20),
                        b'file\x00', b'file\x00abc', b'file\x00' + bytes(65),
                        b'x' * 65536 + b'\x00' + bytes(20)):
            with self.subTest(length=len(payload)):
                with self.assertRaises(ContractError):
                    elf_metadata(linked(payload=payload))
        data = linked()[:-1]
        with self.assertRaises(ContractError):
            elf_metadata(data)

    def test_duplicate_altlink_fails(self):
        with self.assertRaisesRegex(ContractError, 'Duplicate debug link'):
            elf_metadata(with_section(linked(), '.gnu_debugaltlink', b'supp\x00' + bytes(20)))

    def test_nonzero_debuglink_padding_and_truncated_crc_fail(self):
        for payload in (b'x\x00zz' + bytes(4), b'file\x00'):
            with self.assertRaisesRegex(ContractError, 'CRC extent'):
                elf_metadata(with_section(fixture(), '.gnu_debuglink', payload))

    def test_exact_official_tcmalloc_altlink_bytes_decode(self):
        self.assertEqual(len(TCMALLOC_ALT), 87)
        row = elf_metadata(linked(payload=TCMALLOC_ALT))
        self.assertEqual(row['gnuDebugaltlink']['filename'],
                         '/usr/lib/debug/.dwz/x86_64-linux-gnu/libgoogle-perftools4t64.debug')
        self.assertEqual(row['gnuDebugaltlink']['buildId'], 'c7db8991070c2644f5a9378f03bfa160be62ca86')
        self.assertEqual(bytes.fromhex(row['debugLinkPayloads']['.gnu_debugaltlink']['rawHex']), TCMALLOC_ALT)

    def test_official_tcmalloc_actual_package_elf_static_if_available(self):
        supplied = os.environ.get('ABC_CAPTURED_EVIDENCE')
        roots = [Path(supplied)] if supplied else [parent / 'application-evidence-96c096e' for parent in Path(__file__).parents]
        relative = 'code/gperftools-official-package/package-bytes/libgoogle-perftools4t64/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16'
        path = next((root / relative for root in roots if (root / relative).is_file()), None)
        if path is None:
            self.skipTest('optional read-only captured package absent; exact 87-byte oracle remains portable')
        data = path.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), TCMALLOC_SHA)
        row = elf_metadata(data)
        proof = row['debugLinkPayloads']['.gnu_debugaltlink']
        self.assertEqual((proof['offset'], proof['bytes']), (284112, 87))
        self.assertEqual(bytes.fromhex(proof['rawHex']), TCMALLOC_ALT)
        manager = self.manager()
        with patch.object(manager, 'seal_debug_selection', side_effect=AssertionError('startup external access')):
            actual = manager.capture_file(str(path.resolve()), None, time.monotonic() + 10, manager.cap_check)
        self.assertEqual(actual['sha256'], TCMALLOC_SHA)
        self.assertEqual(actual['gnuDebugaltlink'], row['gnuDebugaltlink'])

    def test_matching_relative_and_absolute_altlink_bind_same_retained_input(self):
        for absolute in (False, True):
            with self.subTest(absolute=absolute):
                target = self.root / ('supp-' + str(absolute) + '.debug')
                target.write_bytes(fixture(build_id=ALT_ID))
                self.binary.write_bytes(linked(str(target) if absolute else target.name))
                manager = self.manager()
                row = self.capture(manager)
                manager.prepare_symbols([self.profile()], time.monotonic() + 10)
                candidates = manager.indirect_debug[str(self.binary)]
                alt = next(item for item in candidates if item['kind'] == 'gnu-debugaltlink')
                self.assertEqual(alt['canonicalPath'], str(target))
                self.assertEqual(alt['state'], 'present-bound')
                self.assertEqual(alt['sha256'], hashlib.sha256(target.read_bytes()).hexdigest())
                self.assertIn(str(target), manager.held)
                self.assertEqual(row['externalDebugResolution']['dwarfFunctionAttribution'], 'unknown-not-used')

    def test_supplementary_rel_elf_without_loads_is_never_actual_module(self):
        target = self.root / 'supp.debug'
        target.write_bytes(relocatable_debug())
        with self.assertRaises(ContractError):
            elf_metadata(target.read_bytes())
        manager = self.manager()
        with self.assertRaises(ContractError):
            manager.seal_file(str(target), time.monotonic() + 10)
        manager.close()
        self.binary.write_bytes(linked())
        manager = self.manager()
        self.capture(manager)
        manager.prepare_symbols([self.profile()], time.monotonic() + 10)
        self.assertEqual(manager.files[str(target)]['elfType'], 1)
        self.assertEqual(manager.files[str(target)]['ptLoad'], [])
        self.assertEqual(manager.files[str(target)]['buildId'], ALT_ID)
        self.assertEqual(manager.files[str(target)]['identityRole'], 'external-debug-input')
        with self.assertRaisesRegex(ContractError, 'cannot establish actual-module'):
            manager.capture_file(str(target), None, time.monotonic() + 10, manager.cap_check)

    def test_altlink_buildid_mismatch_fails(self):
        (self.root / 'supp.debug').write_bytes(fixture())
        self.binary.write_bytes(linked())
        manager = self.manager()
        self.capture(manager)
        with self.assertRaisesRegex(ContractError, 'BuildID mismatch'):
            manager.prepare_symbols([self.profile()], time.monotonic() + 10)

    def test_altlink_missing_does_not_allow_escape(self):
        for name in ('../../unapproved.debug', '/etc/unapproved.debug'):
            with self.subTest(name=name):
                self.binary.write_bytes(linked(name))
                manager = self.manager()
                self.capture(manager)
                with self.assertRaisesRegex(ContractError, 'escapes original'):
                    manager.prepare_symbols([self.profile()], time.monotonic() + 10)

    def test_altlink_symlink_escape_fails_before_open(self):
        target = self.root / 'supp.debug'
        target.symlink_to('/etc/passwd')
        self.binary.write_bytes(linked())
        manager = self.manager()
        self.capture(manager)
        with self.assertRaisesRegex(ContractError, 'escapes original'):
            manager.prepare_symbols([self.profile()], time.monotonic() + 10)
        self.assertEqual(set(manager.files), {str(self.binary)})

    def test_altlink_self_and_two_file_cycles_fail(self):
        for cycle in ('self', 'two'):
            with self.subTest(cycle=cycle):
                if cycle == 'self':
                    self.binary.write_bytes(linked(self.binary.name, BUILD_ID))
                else:
                    self.binary.write_bytes(linked())
                    (self.root / 'supp.debug').write_bytes(linked(self.binary.name, BUILD_ID, build_id=ALT_ID))
                manager = self.manager()
                self.capture(manager)
                with self.assertRaisesRegex(ContractError, 'cycle'):
                    manager.prepare_symbols([self.profile()], time.monotonic() + 10)

    def test_same_supplementary_from_two_modules_is_deduplicated_not_cycle(self):
        target = self.root / 'supp.debug'
        target.write_bytes(fixture(build_id=ALT_ID))
        self.binary.write_bytes(linked())
        other = self.root / 'other.so'
        other.write_bytes(linked())
        manager = self.manager()
        self.capture(manager)
        self.capture(manager, other)
        manager.prepare_symbols([self.profile(), self.profile(other)], time.monotonic() + 10)
        self.assertEqual(len(manager.files), 3)
        self.assertEqual(sum(manager.unique_inputs.values()), sum(path.stat().st_size for path in (target, self.binary, other)))

    def test_debug_replacement_and_absent_candidate_appearance_fail_rehash(self):
        for mutation in ('replacement', 'absent-to-file', 'absent-to-directory'):
            with self.subTest(mutation=mutation):
                sub = self.root / mutation
                sub.mkdir()
                binary = sub / 'module.so'
                binary.write_bytes(linked())
                target = sub / 'supp.debug'
                if mutation == 'replacement':
                    target.write_bytes(fixture(build_id=ALT_ID))
                manager = self.manager()
                self.capture(manager, binary)
                manager.prepare_symbols([self.profile(binary)], time.monotonic() + 10)
                if mutation == 'replacement':
                    replacement = sub / 'replacement'
                    replacement.write_bytes(target.read_bytes())
                    os.replace(replacement, target)
                elif mutation == 'absent-to-file':
                    target.write_bytes(fixture(build_id=ALT_ID))
                else:
                    target.mkdir()
                with self.assertRaises(ContractError):
                    manager.rehash(time.monotonic() + 10)

    def test_debug_symlink_retarget_and_broken_target_fail(self):
        target = self.root / 'supp.debug'
        one, two = self.root / 'one.debug', self.root / 'two.debug'
        one.write_bytes(fixture(build_id=ALT_ID))
        two.write_bytes(one.read_bytes())
        target.symlink_to(one)
        self.binary.write_bytes(linked())
        manager = self.manager()
        self.capture(manager)
        manager.prepare_symbols([self.profile()], time.monotonic() + 10)
        target.unlink()
        target.symlink_to(two)
        with self.assertRaisesRegex(ContractError, 'path changed'):
            manager.rehash(time.monotonic() + 10)
        target.unlink()
        target.symlink_to(self.root / 'absent')
        with self.assertRaises(ContractError):
            manager.rehash(time.monotonic() + 10)

    def test_debug_symbol_names_never_replace_exact_main_range_or_fill_gaps(self):
        (self.root / 'supp.debug').write_bytes(fixture([('decorated_nearest_fake', 0x1000, 4096)], build_id=ALT_ID))
        self.binary.write_bytes(linked())
        manager = self.manager()
        row = self.capture(manager)
        manager.prepare_symbols([self.profile(pcs=(0x1110, 0x1130, 0x1144))], time.monotonic() + 10)
        actual = {item['elfOffset']: item['exactRangeSymbolCandidates'] for item in row['metadataProof']['perPcCandidates']}
        self.assertEqual(actual, {0x1110: ['alias', 'outer', 'overlap'], 0x1130: [], 0x1144: []})

    def test_required_file_pc_and_mapping_ambiguity_remain_hard_failures(self):
        manager = self.manager()
        self.capture(manager)
        for profile in (self.profile('/unsealed.so'), {'maps': [], 'buckets': [{'stack': [0x1110], 'counters': [1, 1, 1, 1]}]}):
            with self.assertRaises(ContractError):
                manager.prepare_symbols([profile], time.monotonic() + 10)
        profile = self.profile()
        profile['maps'] *= 2
        with self.assertRaisesRegex(ContractError, 'unique executable mapping'):
            manager.prepare_symbols([profile], time.monotonic() + 10)

    def test_sealed_sha_device_inode_size_and_mapping_ptload_stay_strict(self):
        manager = self.manager()
        expected = file_identity(self.binary)
        for field in ('sha256', 'device', 'inode', 'bytes'):
            wrong = copy.deepcopy(expected)
            wrong[field] = '0' * 64 if field == 'sha256' else wrong[field] + 1
            with self.subTest(field=field):
                with self.assertRaisesRegex(ContractError, 'differs from sealed'):
                    manager.capture_file(str(self.binary), wrong, time.monotonic() + 10, manager.cap_check)
        row = self.capture(manager)
        mapped = dict(start=0x1000, end=0x2000, offset=0, inode=row['inode'],
                      device=(os.major(row['device']), os.minor(row['device'])), path=str(self.binary), permissions='r-xp')
        BoundModules.bind_mappings(row, [mapped])
        for field in ('inode', 'device', 'end'):
            wrong = dict(mapped)
            wrong[field] = (0, 0) if field == 'device' else wrong[field] + (4096 if field == 'end' else 1)
            with self.subTest(field=field):
                with self.assertRaises(ContractError):
                    BoundModules.bind_mappings(row, [wrong])

    def test_section_payload_extent_and_original_deadline_still_fail(self):
        data = bytearray(linked())
        shoff = struct.unpack_from('<Q', data, 40)[0]
        shnum = struct.unpack_from('<H', data, 60)[0]
        struct.pack_into('<Q', data, shoff + (shnum - 1) * 64 + 24, len(data) + 1)
        with self.assertRaisesRegex(ContractError, 'extent'):
            elf_metadata(data)
        manager = self.manager()
        self.capture(manager)
        with self.assertRaisesRegex(ContractError, 'deadline'):
            manager.prepare_symbols([self.profile()], time.monotonic() - 1)

    def test_complete_113_module_metadata_fixture_counts_and_11_altlinks(self):
        rows = captured_rows()
        self.assertEqual(len(rows), 113)
        self.assertEqual(len({row['path'] for row in rows}), 113)
        self.assertEqual(sum(row['loadedAtStartup'] for row in rows), 112)
        self.assertEqual(sum('.gnu_debugaltlink' in row['unsupportedSupplementaryDebugSections'] for row in rows), 11)
        self.assertEqual(sum(bool(row['gnuDebuglink']) for row in rows), 104)
        self.assertEqual(sum(row['bytes'] for row in rows), 291860176)
        self.assertTrue(all(row['metadataProof']['fullSymbolScanComplete'] for row in rows))
        self.assertTrue(all(not row['dynsym'] and not row['symtab'] for row in rows))

    def replay_startup(self, *, mutation=None):
        rows = captured_rows()
        captured = {row['path']: row for row in rows}
        mapped = []
        for row in rows:
            if not row['loadedAtStartup']:
                continue
            for seg in row['ptLoad']:
                if seg['flags'] & 1:
                    mapped.append(dict(path=row['path'], start=row['loadBias'] + (seg['vaddr'] & ~4095),
                        end=row['loadBias'] + ((seg['vaddr'] + seg['memorySize'] + 4095) & ~4095),
                        offset=seg['offset'] & ~4095, permissions='r-xp', inode=row['inode'],
                        device=(os.major(row['device']), os.minor(row['device']))))
        required = {row['path']: None for row in rows if row['loadedAtStartup'] and row['inputPolicy'] != 'inplace-system-elf'}
        lazy = {row['path']: None for row in rows if not row['loadedAtStartup']}
        if mutation == 'missing-critical':
            mapped = [row for row in mapped if row['path'] != next(iter(required))]
        elif mutation == 'inode':
            mapped[0]['inode'] += 1
        elif mutation == 'ptload':
            mapped[0]['end'] += 4096
        elif mutation == 'sha':
            captured[mapped[0]['path']]['sha256'] = 'not-a-sha'
        def capture(manager, path, expected, deadline, cap_check):
            row = copy.deepcopy(captured[path])
            manager.files[path] = row
            return row
        root = self.root / ('replay-' + str(mutation))
        with patch('elf_identity.target_maps', return_value=(b'captured-metadata-replay-only\n', mapped)), \
             patch.object(BoundModules, 'capture_file', new=capture), \
             patch.object(BoundModules, 'seal_indirect_debug', side_effect=AssertionError('startup debug resolution')), \
             patch.object(BoundModules, 'seal_debug_selection', side_effect=AssertionError('startup debug resolution')):
            manager = BoundModules(object(), required, root / 'modules', root / 'evidence',
                                   deadline=time.monotonic() + 10, cap_check=lambda **_: None, presealed=lazy)
        self.managers.append(manager)
        return manager

    def test_complete_113_metadata_replay_startup_and_lazy_identity_need_no_debug(self):
        manager = self.replay_startup()
        self.assertEqual(len(manager.records), 112)
        self.assertEqual(len(manager.deferred), 1)
        self.assertEqual(sum('.gnu_debugaltlink' in row['unsupportedSupplementaryDebugSections'] for row in manager.records.values()), 11)
        self.assertEqual(manager.debug_selections, {})
        self.assertEqual(manager.indirect_debug, {})
        path, row = next(iter(manager.deferred.items()))
        segment = next(item for item in row['ptLoad'] if item['flags'] & 1)
        bias = 0x700000000000
        mapped = dict(path=path, start=bias + (segment['vaddr'] & ~4095),
                      end=bias + ((segment['vaddr'] + segment['memorySize'] + 4095) & ~4095),
                      offset=segment['offset'] & ~4095, inode=row['inode'],
                      device=(os.major(row['device']), os.minor(row['device'])), permissions='r-xp')
        manager.verify_cut({'fileExecutableMaps': [*manager.executable_keys, map_key(mapped)], 'before': [mapped]})
        self.assertEqual((len(manager.records), len(manager.deferred)), (113, 0))
        self.assertTrue(manager.records[path]['loadedIdentityProven'])
        self.assertFalse(manager.records[path]['loadedAtStartup'])
        self.assertEqual(manager.transitions[0]['sha256'], row['sha256'])

    def test_complete_metadata_replay_still_rejects_critical_sha_inode_ptload_errors(self):
        for mutation in ('missing-critical', 'sha', 'inode', 'ptload'):
            with self.subTest(mutation=mutation):
                with self.assertRaises(ContractError):
                    self.replay_startup(mutation=mutation)


if __name__ == '__main__':
    unittest.main()
