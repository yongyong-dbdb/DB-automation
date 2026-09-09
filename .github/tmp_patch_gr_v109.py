from pathlib import Path

p = Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s = p.read_text()

def replace_once(old, new, label):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'{label}: expected 1 match, found {n}')
    s = s.replace(old, new, 1)

replace_once('# mysql_gr_migrate.sh v1.0.8', '# mysql_gr_migrate.sh v1.0.9', 'header version')
replace_once('VERSION=1.0.8', 'VERSION=1.0.9', 'runtime version')

anchor = 'inspect_extra_gtids() {\n'
if s.count(anchor) != 1:
    raise SystemExit(f'inspect anchor count={s.count(anchor)}')

helpers = r'''safe_mysql_object_name() {
    name=$1
    case $name in ''|*[!A-Za-z0-9_$]*) return 1;; *) return 0;; esac
}

show_create_statement() {
    kind=$1; object=$2
    case $kind in
        DATABASE|SCHEMA)
            safe_mysql_object_name "$object" || return 1
            printf 'SHOW CREATE DATABASE `%s`;' "$object"
            ;;
        TABLE|VIEW|EVENT|PROCEDURE|FUNCTION|TRIGGER)
            case $object in *.*) db=${object%%.*}; obj=${object#*.};; *) return 1;; esac
            safe_mysql_object_name "$db" || return 1
            safe_mysql_object_name "$obj" || return 1
            printf 'SHOW CREATE %s `%s`.`%s`;' "$kind" "$db" "$obj"
            ;;
        *) return 1;;
    esac
}

summarize_mysqlbinlog_evidence() {
    i=$1; evidence=$2
    summary="$RUN/node_${i}.errant_gtid_summary.tsv"
    awk -v OFS='\t' '
        BEGIN {
            gtid="UNKNOWN"; db=""
            print "GTID","CATEGORY","OPERATION","OBJECT","DETAIL"
        }
        function emit(cat,op,obj,detail, key) {
            gsub(/\t/," ",detail)
            key=gtid SUBSEP cat SUBSEP op SUBSEP obj SUBSEP detail
            if (!seen[key]++) print gtid,cat,op,obj,detail
        }
        /^use `/ {
            line=$0
            sub(/^use `/,"",line)
            sub(/`.*/,"",line)
            db=line
            next
        }
        /GTID_NEXT[[:space:]]*=/ {
            line=$0
            p=index(line,"\047")
            if (p>0) {
                tail=substr(line,p+1)
                q=index(tail,"\047")
                if (q>0) {
                    x=substr(tail,1,q-1)
                    if (x!="AUTOMATIC") gtid=x
                }
            }
            next
        }
        /^### INSERT INTO / {
            obj=$0; sub(/^### INSERT INTO /,"",obj); sub(/[[:space:]].*$/,"",obj); gsub(/`/,"",obj)
            if (obj !~ /\./ && db!="") obj=db "." obj
            emit("DML","INSERT",obj,"")
            next
        }
        /^### UPDATE / {
            obj=$0; sub(/^### UPDATE /,"",obj); sub(/[[:space:]].*$/,"",obj); gsub(/`/,"",obj)
            if (obj !~ /\./ && db!="") obj=db "." obj
            emit("DML","UPDATE",obj,"")
            next
        }
        /^### DELETE FROM / {
            obj=$0; sub(/^### DELETE FROM /,"",obj); sub(/[[:space:]].*$/,"",obj); gsub(/`/,"",obj)
            if (obj !~ /\./ && db!="") obj=db "." obj
            emit("DML","DELETE",obj,"")
            next
        }
        /^### REPLACE INTO / {
            obj=$0; sub(/^### REPLACE INTO /,"",obj); sub(/[[:space:]].*$/,"",obj); gsub(/`/,"",obj)
            if (obj !~ /\./ && db!="") obj=db "." obj
            emit("DML","REPLACE",obj,"")
            next
        }
        {
            raw=$0
            line=raw
            sub(/^[[:space:]]+/,"",line)
            upper=toupper(line)
            if (upper ~ /^(CREATE|ALTER|DROP|RENAME|TRUNCATE)[[:space:]]+/) {
                split(upper,a,/[[:space:]]+/)
                op=a[1]
                if (match(upper,/(TABLE|EVENT|VIEW|PROCEDURE|FUNCTION|TRIGGER|DATABASE|SCHEMA)[[:space:]]+/)) {
                    kind=substr(upper,RSTART,RLENGTH)
                    gsub(/[[:space:]]/,"",kind)
                    obj=substr(line,RSTART+RLENGTH)
                    sub(/^[[:space:]]+/,"",obj)
                    sub(/^[Ii][Ff][[:space:]]+[Nn][Oo][Tt][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)
                    sub(/^[Ii][Ff][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)
                    sub(/[[:space:](;,].*$/,"",obj)
                    gsub(/`/,"",obj)
                    if (kind!="DATABASE" && kind!="SCHEMA" && obj !~ /\./ && db!="") obj=db "." obj
                    if (obj=="") obj="UNKNOWN"
                    emit("DDL",op " " kind,obj,line)
                } else {
                    emit("DDL",op " OBJECT","UNKNOWN",line)
                }
            }
        }
    ' "$evidence" > "$summary"
    chmod 600 "$summary"

    dml_count=$(awk -F '\t' 'NR>1 && $2=="DML" {n++} END{print n+0}' "$summary")
    ddl_count=$(awk -F '\t' 'NR>1 && $2=="DDL" {n++} END{print n+0}' "$summary")
    total=$(awk 'END{print NR>0?NR-1:0}' "$summary")
    log '[ Extra GTID Summary ]'
    if [ "$total" -eq 0 ]; then
        log '  No DML/DDL operation could be summarized automatically. Review the raw mysqlbinlog evidence.'
    else
        awk -F '\t' 'NR>1 && shown<80 {printf "  %s | %s | %s | %s\n",$1,$2,$3,$4; shown++} END{if (NR-1>80) printf "  ... %d additional summary rows saved in the TSV file\n",(NR-1)-80}' "$summary" >&2
    fi
    log "  DML summary rows : $dml_count"
    log "  DDL summary rows : $ddl_count"
    log "  Summary evidence : $summary"
    [ "$dml_count" -eq 0 ] || log '  NOTE: INSERT/UPDATE/DELETE/REPLACE combinations are NOT treated as compensating changes; current row equality is not inferred.'
    [ "$ddl_count" -eq 0 ] || log '  NOTE: DDL objects are compared read-only against authoritative node 1 when the object name/type is safely parseable.'
}

compare_ddl_metadata() {
    i=$1
    summary="$RUN/node_${i}.errant_gtid_summary.tsv"
    [ -s "$summary" ] || return 0
    list="$RUN/node_${i}.ddl_objects.tsv"
    awk -F '\t' 'NR>1 && $2=="DDL" {print $3 "\t" $4}' "$summary" | sort -u > "$list"
    [ -s "$list" ] || return 0
    dir="$RUN/node_${i}.ddl_metadata"
    mkdir -p "$dir"; chmod 700 "$dir"
    log '[ DDL Current Metadata Comparison ]'
    tab=$(printf '\t')
    while IFS="$tab" read -r operation object; do
        [ -n "$operation" ] || continue
        kind=${operation#* }
        if ! stmt=$(show_create_statement "$kind" "$object"); then
            log "  SKIP  : $operation $object (name/type not safe for automatic SHOW CREATE)"
            continue
        fi
        safe=$(printf '%s_%s' "$kind" "$object" | tr './` ' '____')
        src="$dir/${safe}.source.tsv"
        mem="$dir/${safe}.node_${i}.tsv"
        src_ok=yes; mem_ok=yes
        if ! sql 1 "$stmt" > "$src" 2> "$src.err"; then src_ok=no; fi
        if ! sql "$i" "$stmt" > "$mem" 2> "$mem.err"; then mem_ok=no; fi
        if [ "$src_ok" = yes ] && [ "$mem_ok" = yes ]; then
            if cmp -s "$src" "$mem"; then
                log "  MATCH : $kind $object"
            else
                diff -u "$src" "$mem" > "$dir/${safe}.diff" || :
                log "  DIFF  : $kind $object -> $dir/${safe}.diff"
            fi
        else
            src_cmd="$dir/${safe}.source_check.sh"
            mem_cmd="$dir/${safe}.node_${i}_check.sh"
            write_mysql_readonly_command 1 "$stmt" "$src_cmd"
            write_mysql_readonly_command "$i" "$stmt" "$mem_cmd"
            log "  MANUAL: $kind $object metadata could not be read automatically."
            log "          Source check: $src_cmd"
            log "          Node check  : $mem_cmd"
        fi
    done < "$list"
    log "  Metadata evidence directory: $dir"
}

postprocess_mysqlbinlog_evidence() {
    i=$1; evidence=$2
    summarize_mysqlbinlog_evidence "$i" "$evidence"
    compare_ddl_metadata "$i"
    log 'Decision rule: extra GTIDs still block GR join even when current metadata appears equal; reconcile/reprovision or abort after review.'
}

'''
s = s.replace(anchor, helpers + anchor, 1)

old_direct = '''            log "  mysqlbinlog evidence              : $output_file"\n            log '  WARNING: The evidence can contain SQL and row values; the file is stored under the protected run directory.'\n            return 0\n'''
new_direct = '''            log "  mysqlbinlog evidence              : $output_file"\n            log '  WARNING: The evidence can contain SQL and row values; the file is stored under the protected run directory.'\n            postprocess_mysqlbinlog_evidence "$i" "$output_file"\n            return 0\n'''
replace_once(old_direct, new_direct, 'direct postprocess')

old_remote = '''        log "  mysqlbinlog evidence              : $output_file"\n        log '  WARNING: The evidence can contain SQL and row values; the file is stored under the protected run directory.'\n    else\n'''
new_remote = '''        log "  mysqlbinlog evidence              : $output_file"\n        log '  WARNING: The evidence can contain SQL and row values; the file is stored under the protected run directory.'\n        postprocess_mysqlbinlog_evidence "$i" "$output_file"\n    else\n'''
replace_once(old_remote, new_remote, 'remote postprocess')

old_next = '''    log 'NEXT CHECKS:'\n    if [ -s "$RUN/node_${i}.errant_gtid.mysqlbinlog.txt" ]; then\n        log "  1) Review decoded extra-GTID evidence: $RUN/node_${i}.errant_gtid.mysqlbinlog.txt"\n    elif [ -s "$RUN/node_${i}.errant_gtid.mysqlbinlog.err" ]; then\n        log "  1) Review mysqlbinlog error: $RUN/node_${i}.errant_gtid.mysqlbinlog.err"\n        [ ! -f "$RUN/node_${i}.mysqlbinlog_command.sh" ] || log "     Read-only retry command: $RUN/node_${i}.mysqlbinlog_command.sh"\n    else\n        log "  1) Review GTID evidence: $RUN/node_${i}.gtid_compare.tsv"\n    fi\n    log "  2) Review inspection summary: $RUN/node_${i}.errant_gtid_inspection.tsv"\n    log '  3) Keep the migration stopped; do not run cutover while extra GTIDs remain.'\n    log '  4) After reviewed reconciliation/reprovisioning, rerun precheck and initialize if instance identity is unchanged.'\n    log '     If server_uuid/instance identity changed, use a fresh MYSQL_GR_WORK_ROOT and run discover again.'\n'''
new_next = '''    log 'NEXT CHECKS:'\n    if [ -s "$RUN/node_${i}.errant_gtid_summary.tsv" ]; then\n        log "  1) Review automatic per-GTID DML/DDL summary: $RUN/node_${i}.errant_gtid_summary.tsv"\n        [ ! -d "$RUN/node_${i}.ddl_metadata" ] || log "  2) Review Source/Node DDL metadata comparisons: $RUN/node_${i}.ddl_metadata"\n        log "  3) Review raw decoded evidence if needed: $RUN/node_${i}.errant_gtid.mysqlbinlog.txt"\n    elif [ -s "$RUN/node_${i}.errant_gtid.mysqlbinlog.err" ]; then\n        log "  1) Review mysqlbinlog error: $RUN/node_${i}.errant_gtid.mysqlbinlog.err"\n        [ ! -f "$RUN/node_${i}.mysqlbinlog_command.sh" ] || log "     Read-only retry command: $RUN/node_${i}.mysqlbinlog_command.sh"\n        log "  2) Review GTID comparison: $RUN/node_${i}.gtid_compare.tsv"\n    else\n        log "  1) Review GTID evidence: $RUN/node_${i}.gtid_compare.tsv"\n    fi\n    log "  4) Review inspection summary: $RUN/node_${i}.errant_gtid_inspection.tsv"\n    log '  5) Keep the migration stopped; do not run cutover while extra GTIDs remain.'\n    log '  6) After reviewed reconciliation/reprovisioning, rerun precheck and initialize if instance identity is unchanged.'\n    log '     If server_uuid/instance identity changed, use a fresh MYSQL_GR_WORK_ROOT and run discover again.'\n'''
replace_once(old_next, new_next, 'abort next checks')

replace_once(
    '# v1.0.8: client option-group compatibility, preflight checks, local-first binlog inspection and abort guidance.\n',
    '# v1.0.8: client option-group compatibility, preflight checks, local-first binlog inspection and abort guidance.\n# v1.0.9: generic per-GTID DML/DDL summaries and safe current-metadata comparison for divergent members.\n',
    'version note')

p.write_text(s)
