import sys,re,collections,statistics as st
# per binary, per pass: median over rounds of main ms/frame, dropped %, hitch ms/s, p99
data=collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(list)))
order=[]
for l in open(sys.argv[1]):
    p=l.split()
    if len(p)<3: continue
    d,name=p[0],p[2]
    if d not in order: order.append(d)
    if name in ('list',) or name.startswith('pointer'): continue
    if name=='memory':
        data[d]['memory']['rss'].append(float(re.search(r'rss=([\d.]+)',l).group(1))); continue
    m=re.search(r'main=([\d.]+)ms/frame',l); data[d][name]['main'].append(float(m.group(1)))
    data[d][name]['drop'].append(float(re.search(r'dropped=\d+ \(([\d.]+)%\)',l).group(1)))
    data[d][name]['hitch'].append(float(re.search(r'hitch=([\d.]+)ms/s',l).group(1)))
    data[d][name]['p99'].append(float(re.search(r'p99=([\d.]+)',l).group(1)))
    n=re.search(r'instr=([\d.]+)M/frame',l); data[d][name]['instr'].append(float(n.group(1)) if n else 0)
    c=re.search(r'cpu=([\d.]+)ms/frame',l); data[d][name]['cpu'].append(float(c.group(1)) if c else 0)
    dm=re.search(r'frames=(\d+).*dist=(\d+)pt',l)
    if dm and int(dm.group(2))>0 and n: data[d][name]['perpt'].append(float(n.group(1))*int(dm.group(1))/int(dm.group(2))*1000)
    data[d][name]['busy'].append(float(re.search(r'mainBusy=([\d.]+)%',l).group(1)))
passes=['DRAG-UP-COLD','DRAG-DOWN-WARM','FLING-UP','FLING-DOWN','TOTAL','DRAG-UP-LIVE','PREPEND-PAGES']
print("median over rounds (n=%s)"%{d:len(data[d]['TOTAL']['main']) for d in order})
print(f"{'pass':16s} " + " | ".join(f"{d:>40s}" for d in order))
print(f"{'':16s} " + " | ".join(f"{'Minstr/kpt cpu ms/fr drop% hitch p99':>40s}" for d in order))
for ps in passes:
    cells=[]
    for d in order:
        x=data[d][ps]
        if not x['main']: cells.append(' '*40); continue
        pp=st.median(x['perpt']) if x['perpt'] else float('nan')
        cells.append(f"{pp:10.0f} {st.median(x['cpu']):9.2f} {st.median(x['drop']):5.1f} {st.median(x['hitch']):5.1f} {st.median(x['p99']):4.1f}")
    print(f"{ps:16s} " + " | ".join(f"{c:>40s}" for c in cells))
print("rss MB: " + ", ".join(f"{d}={st.median(data[d]['memory']['rss']):.0f}" for d in order if data[d]['memory']['rss']))
