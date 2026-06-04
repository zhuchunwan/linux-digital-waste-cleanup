# Reasonix project memory

Notes the user pinned via the `#` prompt prefix. The whole file is
loaded into the immutable system prefix every session — keep it terse.

- 5. 模拟 24 小时后（改时间戳）                                    │
  │  python3 -c "                                                     │
  │  import time                                                      │
  │  path='logs/docker_pending_delete.log'                             │
  │  now=int(time.time())                                             │
  │  old=now-26*3600                                                  │
  │  lines=open(path).readlines()                                     │
  │  with open(path,'w') as f:                                        │
  │      for l in lines:                                              │
  │          if l.startswith('#') or not l.strip(): f.write(l);continue│
  │          p=l.strip().split('|')                                   │
  │          p[3]=str(old);p[4]=time.strftime('%Y-%m-%dT%H:%M:%S',    │
  │          time.localtime(old))                                     │
  │          f.write('|'.join(p)+'\n')                                │
  │  print('done')"
这步是否错误，是否需要修改？请将如何将不满7天的容器改到七天后，和24小时后的方法补充到GSH_README.txt中
