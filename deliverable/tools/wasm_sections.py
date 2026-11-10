import sys
d=open(sys.argv[1],'rb').read()
def leb(i):
    r=0;s=0
    while True:
        b=d[i];i+=1;r|=(b&0x7f)<<s;s+=7
        if not b&0x80:return r,i
i=8
while i<len(d):
    sid=d[i];i+=1;sz,i=leb(i)
    print("section",sid,"size",sz)
    if sid==11:
        n,j=leb(i);big=[]
        for _ in range(n):
            flag,j=leb(j)
            if flag==0:
                assert d[j]==0x41; _,j=leb(j+1); assert d[j]==0x0b; j+=1
            elif flag==2: _,j=leb(j); j+=0; raise SystemExit("flag2")
            ln,j=leb(j);big.append((ln,j));j+=ln
        big.sort(reverse=True);print(" data segments",n,"largest",[b[0] for b in big[:5]])
    i+=sz
