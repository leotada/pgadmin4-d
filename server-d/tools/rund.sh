#!/bin/bash
# usage: rund.sh  -- (re)starts the D server on :5056 in desktop mode with the scratch data dir
SP=/tmp/claude-1000/-home-leonardo-Projetos-pgadmin4-9-18/861967f2-de8a-458d-b21e-5a788ada5c74/scratchpad
[ -f $SP/d.pid ] && kill $(cat $SP/d.pid) 2>/dev/null
sleep 0.5
cp $SP/ddata/config_local.json /home/leonardo/Projetos/pgadmin4-9.18/web/config_local.json
cd /home/leonardo/Projetos/pgadmin4-9.18/server-d
nohup ./bin/pgadmin4-d --web-dir ../web --port 5056 > $SP/d.log 2>&1 &
echo $! > $SP/d.pid
sleep 2.5
rm -f /home/leonardo/Projetos/pgadmin4-9.18/web/config_local.json
