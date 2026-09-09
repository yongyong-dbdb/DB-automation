from pathlib import Path
p=Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s=p.read_text()

def rep(old,new,label):
    global s
    c=s.count(old)
    if c!=1: raise SystemExit(f'{label}: expected 1, found {c}')
    s=s.replace(old,new,1)

rep('# mysql_gr_migrate.sh v1.0.10','# mysql_gr_migrate.sh v1.0.11','header')
rep('VERSION=1.0.10','VERSION=1.0.11','version')
rep('for c in awk sed grep sort cut tr head tail dirname basename mktemp cmp diff date cp mv rm mkdir cat chmod; do',
    'for c in awk sed grep sort cut tr head tail dirname basename mktemp cmp diff date cp mv rm mkdir cat chmod readlink sha256sum tee stat id sleep; do',
    'utility list')
old='''                if (match(upper,/(TABLE|EVENT|VIEW|PROCEDURE|FUNCTION|TRIGGER|DATABASE|SCHEMA)[[:space:]]+/)) {\n                    kind=substr(upper,RSTART,RLENGTH)\n                    gsub(/[[:space:]]/,"",kind)\n                    obj=substr(line,RSTART+RLENGTH)\n                    sub(/^[[:space:]]+/,"",obj)\n                    sub(/^[Ii][Ff][[:space:]]+[Nn][Oo][Tt][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)\n                    sub(/^[Ii][Ff][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)\n                    sub(/[[:space:](;,].*$/,"",obj)\n                    gsub(/`/,"",obj)\n                    if (kind!="DATABASE" && kind!="SCHEMA" && obj !~ /\\./ && db!="") obj=db "." obj\n                    if (obj=="") obj="UNKNOWN"\n                    emit("DDL",op " " kind,obj,line)\n                } else {'''
new='''                if (match(upper,/(TABLE|EVENT|VIEW|PROCEDURE|FUNCTION|TRIGGER|DATABASE|SCHEMA)[[:space:]]+/)) {\n                    kind=substr(upper,RSTART,RLENGTH)\n                    gsub(/[[:space:]]/,"",kind)\n                    rest=substr(line,RSTART+RLENGTH)\n                    sub(/^[[:space:]]+/,"",rest)\n                    if (op=="RENAME" && kind=="TABLE") {\n                        clean=rest; gsub(/`/,"",clean)\n                        pair_count=split(clean,pairs,/,/)\n                        for (pi=1; pi<=pair_count; pi++) {\n                            pair=pairs[pi]\n                            sub(/^[[:space:]]+/,"",pair); sub(/[[:space:]]+$/,"",pair)\n                            n=split(pair,rn,/[[:space:]]+[Tt][Oo][[:space:]]+/)\n                            if (n==2) {\n                                src=rn[1]; dst=rn[2]\n                                sub(/[[:space:];].*$/,"",src); sub(/[[:space:];].*$/,"",dst)\n                                if (src !~ /\\./ && db!="") src=db "." src\n                                if (dst !~ /\\./ && db!="") dst=db "." dst\n                                emit("DDL",op " " kind,src,line)\n                                emit("DDL",op " " kind,dst,line)\n                            } else emit("DDL",op " " kind,"UNKNOWN",line)\n                        }\n                    } else {\n                        obj=rest\n                        sub(/^[Ii][Ff][[:space:]]+[Nn][Oo][Tt][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)\n                        sub(/^[Ii][Ff][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)\n                        sub(/[[:space:](;,].*$/,"",obj)\n                        gsub(/`/,"",obj)\n                        if (kind!="DATABASE" && kind!="SCHEMA" && obj !~ /\\./ && db!="") obj=db "." obj\n                        if (obj=="") obj="UNKNOWN"\n                        emit("DDL",op " " kind,obj,line)\n                    }\n                } else {'''
rep(old,new,'DDL parser')
rep('# v1.0.10: POSIX-awk conditional fix and controller utility/awk compatibility preflight before mutation.\n',
    '# v1.0.10: POSIX-awk conditional fix and controller utility/awk compatibility preflight before mutation.\n# v1.0.11: broader controller utility preflight and RENAME TABLE source/target metadata coverage.\n',
    'note')
p.write_text(s)
