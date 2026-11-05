# Synthetic curl set: angle hills; gyro = d(angle)/dt about an axis; accel = gravity rotated by the angle, plus noise.
import math, random, sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
import rep_engine as re_

def rot(v, axis, ang):
    # Rodrigues rotation of v about unit axis by ang (rad)
    ax,ay,az=axis; x,y,z=v; c=math.cos(ang); s=math.sin(ang)
    dot=ax*x+ay*y+az*z
    cx=ay*z-az*y; cy=az*x-ax*z; cz=ax*y-ay*x
    return (x*c+cx*s+ax*dot*(1-c), y*c+cy*s+ay*dot*(1-c), z*c+cz*s+az*dot*(1-c))

def curl_set(reps=20, period=3.0, amp=110.0, axis=(1,0,0), sign=1.0, bias=(1.5,-0.8,0.4), seed=1, rest=1.5):
    random.seed(seed)
    dt=0.01; t=0.0; out=[]; g0=(0,0,9.81)
    # timeline: rest, then reps with a short hold at top/bottom
    timeline=[('rest',rest)]
    for _ in range(reps):
        timeline += [('up',period*0.4),('top',period*0.1),('down',period*0.4),('bottom',period*0.1)]
    timeline.append(('rest',rest))
    theta=0.0
    for phase,dur in timeline:
        n=int(dur/dt)
        for i in range(n):
            if phase=='up': theta = amp*0.5*(1-math.cos(math.pi*i/n))
            elif phase=='down': theta = amp*0.5*(1+math.cos(math.pi*i/n))
            elif phase=='top': theta=amp
            else: theta=0.0
            out.append((t,theta)); t+=dt
    samples=[]; prev=out[0][1]
    for (t,theta) in out:
        omega=(theta-prev)/dt; prev=theta
        w=[axis[k]*omega*sign + bias[k] + random.gauss(0,3) for k in range(3)]
        a=rot(g0, axis, -math.radians(theta*sign))
        a=[a[k]+random.gauss(0,0.4) for k in range(3)]
        samples.append((t,tuple(a),tuple(w)))
    return samples

if __name__=='__main__':
    base=curl_set()
    p=re_.learn(base,20)
    print('learned', {k:(round(v,3) if isinstance(v,float) else v) for k,v in p.items() if k not in('template',)} if not p.get('failed') else p)
    for label,kw in [('same',{}),('flipped sign',{'sign':-1.0}),('other axis',{'axis':(0,0.707,0.707)}),('other axis flipped',{'axis':(0,-0.707,0.707),'sign':-1.0}),('fast',{'period':1.5}),('slow',{'period':5.0}),('small 60deg',{'amp':60.0})]:
        s=curl_set(seed=2,**kw)
        e=re_.RepEngine(p); [e.push(*x) for x in s]
        g=re_.RepEngine(); [g.push(*x) for x in s]
        print(f"{label:22s} profile {e.reps:>3}  generic {g.reps:>3}  rep sources {set(e.rep_sources)}")

def with_prefix_rotation(samples, deg=40.0, axis=(0,1,0)):
    """Rotate the whole set by a fixed mounting change, plus a posture change of `deg` during the first 1 s (rack lift)."""
    out=[]
    for i,(t,a,g) in enumerate(samples):
        frac=min(1.0, t/1.0)
        ang=math.radians(deg*frac)
        a2=rot(a, axis, -ang)
        w=(deg if t<1.0 else 0.0)
        g2=tuple(g[k]+axis[k]*w for k in range(3))
        out.append((t,a2,g2))
    return out

if __name__=='__main__':
    print('--- harder cases')
    base=curl_set(); p=re_.learn(base,20)
    cases={
      'rack lift first': with_prefix_rotation(curl_set(seed=3)),
      'hold at top 2s': curl_set(seed=4, period=3.0),  # same shape; see below for a real hold
    }
    # real hold at top: stretch 'top' phase
    def curl_hold(reps=20, hold=2.0, seed=5):
        s=curl_set(reps=reps, seed=seed)
        return s
    for label,s in cases.items():
        e=re_.RepEngine(p); [e.push(*x) for x in s]
        g=re_.RepEngine(); [g.push(*x) for x in s]
        print(f"{label:22s} profile {e.reps:>3}  generic {g.reps:>3}")
