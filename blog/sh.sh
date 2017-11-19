function out(){
cat << EOF
---
author: "Takuma Kume"
title: "${1}"
linktitle: "${1}"
date: ${2}T00:00:00+09:00
draft: false
highlight: true
---

EOF
}

while read line
do
  echo "================="
  echo $line
  f=`echo $line | sed 's/md,.*/md/g'`
  t=`echo $line | sed 's/.*,//g'`
  d=`echo $f | cut -c 1-10`
  echo $f
  echo $t
  echo $d
  out "$t" "$d" > "$f"
done < <(cat list | grep "[0-9]-")
