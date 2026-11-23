import json,math,heapq,sys,runpy
from pathlib import Path
from shapely.geometry import Polygon,LineString,Point
from shapely.ops import unary_union,nearest_points
R=Path(__file__).resolve().parent.parent;d=json.loads((Path(sys.argv[1]) if len(sys.argv)>1 else R/'art/operational-routing/traced-input.json').read_text());p=json.loads((R/'art/gate-layout-review/gate-layout-proposal.json').read_text());lookup={n['id']:n for n in d['nodes']};nextnode=max(lookup)+1;nextedge=max(e['id'] for e in d['edges'])+1
aprons=unary_union([Polygon(x) for x in p['aprons']]+[Polygon(p['fighter_apron'])]);roofs=unary_union([Polygon(x) for x in p['roof_geometry']]);
# Preserve every authored node and edge. New stand access is kept in separate
# local spurs and is never written back into the developer's saved draft.
chosen=[next(s for s in p['stands'] if s['index']==i) for i in p['plans']['mixed']['indices']]
chosen += [s for s in p['fighter_stands'] if s['index'] in p['military_mixed_fighters']]+p['military_cargo_stands']
adj={n['id']:set() for n in d['nodes'] if n['layer']=='Aircraft taxiways'}
for e in d['edges']:
 if e['a'] in adj and e['b'] in adj:adj[e['a']].add(e['b']);adj[e['b']].add(e['a'])
active=set(adj);queue=[i for i in active if len(adj[i])<2]
while queue:
 i=queue.pop()
 if i not in active:continue
 active.remove(i)
 for j in adj[i]:
  adj[j].discard(i)
  if j in active and len(adj[j])<2:queue.append(j)
core=[LineString([(lookup[k]['point']['x'],lookup[k]['point']['y']) for k in [e['a'],e['b']]]) for e in d['edges'] if e['a'] in active and e['b'] in active]
def add_node(x,y,layer):
 global nextnode
 for n in d['nodes']:
  if n['layer']==layer and math.dist([x,y],[n['point']['x'],n['point']['y']])<.01:return n['id']
 n={'id':nextnode,'layer':layer,'point':{'x':x,'y':y}};d['nodes'].append(n);lookup[nextnode]=n;nextnode+=1;return n['id']
def lane(coords,layer):
 global nextedge
 ids=[add_node(*q,layer) for q in coords]
 for a,b in zip(ids,ids[1:]):
  if a!=b:d['edges'].append({'id':nextedge,'a':a,'b':b,'access':[0] if layer=='Aircraft taxiways' else list(range(1,17))});nextedge+=1
def connect(q,layer):
 global nextedge
 es=[e for e in d['edges'] if lookup[e['a']]['layer']==layer]
 e=min(es,key=lambda e:LineString([(lookup[k]['point']['x'],lookup[k]['point']['y']) for k in [e['a'],e['b']]]).distance(Point(q)))
 a,b=[(lookup[k]['point']['x'],lookup[k]['point']['y']) for k in [e['a'],e['b']]];line=LineString([a,b]);t=nearest_points(Point(q),line)[1];v=(t.x,t.y)
 lane([a,v,b],layer);lane([v,q],layer);return v
out=[]
for i,s in enumerate(chosen):
 start=(s['x'],s['y']);h=s['heading'];mil=s['kind'] in ['fighter','cargo'];
 # Reverse clear of the terminal first; military parking faces out.
 reverse=(start[0]-math.cos(h)*max(5,s['length']*.40),start[1]-math.sin(h)*max(5,s['length']*.40))
 if mil:reverse=(start[0]+math.cos(h)*9,start[1]+math.sin(h)*9)
 allowed=aprons.union(unary_union(core).buffer(7)).buffer(.8).difference(roofs.buffer(1))
 obstacles=roofs.buffer(2)
 blocked=obstacles.buffer(-.01);paving=allowed.buffer(5)
 def clear(a,b):return not LineString([a,b]).intersects(blocked) and paving.covers(LineString([a,b]))
 if not clear(start,reverse):reverse=start
 options=[]
 lines=core if not mil else [LineString([(864.8,378.5),(936.7,396.4)])]
 for line in sorted(lines,key=lambda line:line.distance(Point(reverse)))[:100]:
  z=nearest_points(Point(reverse),line)[1];q=(z.x,z.y)
  if math.dist(reverse,q)<170:options.append(q)
 # Visibility graph navigates around roofs rather than drawing straight apron shortcuts.
 points=[reverse]+options
 for poly in list(getattr(obstacles,'geoms',[obstacles]))+list(getattr(allowed,'geoms',[allowed])):
  for q in poly.simplify(1.0,preserve_topology=True).exterior.coords:
   if math.dist(start,q)<180:points.append(q)
 dist=[float('inf')]*len(points);prev={};dist[0]=0;heap=[(0,0)];goal=None
 while heap:
  cost,u=heapq.heappop(heap)
  if cost!=dist[u]:continue
  if 0<u<=len(options):goal=u;break
  for v in range(1,len(points)):
   if v==u or not clear(points[u],points[v]):continue
   c=cost+math.dist(points[u],points[v])
   if c<dist[v]:dist[v]=c;prev[v]=u;heapq.heappush(heap,(c,v))
 if goal is None:
  target=unary_union(lines);step=2.5;origin=reverse;queue=[(0,0,0)];costs={(0,0):0};parents={};endcell=None
  def xy(cell):return(origin[0]+cell[0]*step,origin[1]+cell[1]*step)
  while queue:
   cost,gx,gy=heapq.heappop(queue);cell=(gx,gy)
   if cost>costs[cell]:continue
   pos=xy(cell);nearest=nearest_points(Point(pos),target)[1];q=(nearest.x,nearest.y)
   if math.dist(pos,q)<4 and clear(pos,q):endcell=cell;destination=q;break
   for ox,oy in [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)]:
    n=(gx+ox,gy+oy)
    if max(abs(n[0]),abs(n[1]))>75:continue
    c=cost+math.hypot(ox,oy)*step
    if c>=costs.get(n,float('inf')) or not clear(pos,xy(n)):continue
    costs[n]=c;parents[n]=cell;heapq.heappush(queue,(c,n[0],n[1]))
  assert endcell is not None,('no paved grid access',i,start,reverse)
  cells=[endcell]
  while cells[-1]!=(0,0):cells.append(parents[cells[-1]])
  raw=[xy(c) for c in reversed(cells)]+[destination];smooth=[raw[0]];k=0
  while k<len(raw)-1:
   j=len(raw)-1
   while j>k+1 and not clear(raw[k],raw[j]):j-=1
   smooth.append(raw[j]);k=j
  access=[start]+smooth;port=access[-1]
 else:
  ids=[goal]
  while ids[-1]!=0:ids.append(prev[ids[-1]])
  access=[start]+[points[j] for j in reversed(ids)]
  port=access[-1]
 # Join the selected corridor by splitting its actual saved edge.
 connect(port,'Aircraft taxiways');lane(access,'Aircraft taxiways')
 # Vehicles use the same apron access, connected to the independent service graph.
 connect(port,'Vehicle roads');lane(access,'Vehicle roads')
 name=('F'+str(s['index']-999)) if s['kind']=='fighter' else 'M1' if s['kind']=='cargo' else 'G'+str(i+1)
 out.append(dict(name=name,position=list(start),heading=h,port=list(port),access=[list(q) for q in access],kind=s['kind'],length=s['length'],span=s['span'],region=s['region']))
 print(name,s['kind'],'access',round(LineString(access).length,1),'points',len(access))
# Service staging is attached to the user's vehicle graph; no city shortcuts.
(R/'AirTrafficControl/airport-routes.json').write_text(json.dumps(d,separators=(',',':')))
(R/'art/gate-layout-review/operational-layout.json').write_text(json.dumps(out,indent=2))
# Operational stand data now lives in the airport package, never generated Swift.
package_folder=R/'AirTrafficControl/Airports/delhi'
package_path=package_folder/'airport.json'
airport=json.loads(package_path.read_text())
previous={g['name']:g for g in airport['stands']}
stands=[]
for index,stand in enumerate(out):
 old=previous.get(stand['name'],{})
 x,y=stand['position'];h=stand['heading']
 point=lambda pair:dict(x=round(pair[0],5),y=round(pair[1],5))
 access=[point(q) for q in stand['access']]
 purpose='militaryFighter' if stand['kind']=='fighter' else 'militaryCargo' if stand['kind']=='cargo' else 'passenger'
 stands.append(dict(id=old.get('id',f'stand-{index}'),name=stand['name'],position=point((x,y)),nose=point((x+math.cos(h)*10,y+math.sin(h)*10)),port=point(stand['port']),maxLength=round(stand['length'],3),maxSpan=round(stand['span'],3),purpose=purpose,access=access,tugBay=access[1],departureRunways=old.get('departureRunways',[r['id'] for r in airport['runways']]),tugRequired=old.get('tugRequired',purpose=='passenger')))
airport['stands']=stands
package_path.write_text(json.dumps(airport,indent=2)+'\n')
(package_folder/airport['routesFile']).write_bytes((R/'AirTrafficControl/airport-routes.json').read_bytes())
# Do not interpret this script's optional input draft argument as a package path.
import subprocess
subprocess.run([sys.executable,str(R/'scripts/prepare_playable_routes.py'),str(package_folder)],check=True)
