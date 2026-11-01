#!/bin/bash
# site-analytics.sh - вставить счётчики во все .html сайта (перед </head>).
# Повторный запуск заменяет старую вставку, ничего не дублирует.
#   sudo bash site-analytics.sh --site /var/www/ПАПКА [--clarity ID] [--ga G-XXXX] [--gsv ТОКЕН]
#     --clarity  Microsoft Clarity (ID проекта)
#     --ga       Google Analytics 4 (Measurement ID G-...)
#     --gsv      Google Search Console: токен из <meta name="google-site-verification" content="...">
# Откат:  sudo bash site-analytics.sh --site /var/www/ПАПКА --remove
set -u
MARK_B='<!-- analytics:begin -->'; MARK_E='<!-- analytics:end -->'
SITE=""; CL=""; GA=""; GSV=""; REMOVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --site) SITE=${2:-}; shift 2;;
        --clarity) CL=${2:-}; shift 2;;
        --ga) GA=${2:-}; shift 2;;
        --gsv) GSV=${2:-}; shift 2;;
        --remove) REMOVE=1; shift;;
        *) echo "Неизвестный параметр: $1"; exit 1;;
    esac
done
SITE=${SITE%/}
[ -n "$SITE" ] && [ -d "$SITE" ] || { echo "Укажи папку сайта: --site /var/www/ПАПКА"; exit 1; }

if [ "$REMOVE" -eq 1 ]; then
    find "$SITE" -name '*.html' -print0 | xargs -0 -r sed -i "/$MARK_B/,/$MARK_E/d"
    echo "Счётчики убраны из $SITE"; exit 0
fi

[ -z "$CL$GA$GSV" ] && { echo "Нечего вставлять: укажи --clarity / --ga / --gsv"; exit 1; }
[ -z "$CL" ]  || [[ "$CL"  =~ ^[a-z0-9]{6,20}$ ]]      || { echo "Clarity ID неверный: '$CL'"; exit 1; }
[ -z "$GA" ]  || [[ "$GA"  =~ ^G-[A-Z0-9]{6,14}$ ]]    || { echo "GA ID неверный: '$GA' (вид G-XXXXXXXXXX)"; exit 1; }
[ -z "$GSV" ] || [[ "$GSV" =~ ^[A-Za-z0-9_-]{20,60}$ ]] || { echo "Токен Search Console неверный: '$GSV'"; exit 1; }

BK=/root/site-backup-$(date +%F-%H%M).tar.gz
tar -czf "$BK" -C "$(dirname "$SITE")" "$(basename "$SITE")" && echo "Бэкап сайта: $BK"

W=www; SNIP=$(mktemp)
{
  echo "$MARK_B"
  [ -n "$GSV" ] && echo "<meta name=\"google-site-verification\" content=\"$GSV\" />"
  [ -n "$CL" ]  && echo "<script>(function(c,l,a,r,i,t,y){c[a]=c[a]||function(){(c[a].q=c[a].q||[]).push(arguments)};t=l.createElement(r);t.async=1;t.src=\"https://$W.clarity.ms/tag/\"+i;y=l.getElementsByTagName(r)[0];y.parentNode.insertBefore(t,y);})(window,document,\"clarity\",\"script\",\"$CL\");</script>"
  [ -n "$GA" ]  && echo "<script async src=\"https://$W.googletagmanager.com/gtag/js?id=$GA\"></script>" \
                && echo "<script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','$GA');</script>"
  echo "$MARK_E"
} > "$SNIP"

n=0
while IFS= read -r -d '' f; do
    sed -i "/$MARK_B/,/$MARK_E/d" "$f"
    if grep -qi '</head>' "$f"; then
        awk -v s="$SNIP" 'BEGIN{while((getline l<s)>0) buf=buf l "\n"} !done && (p=index(tolower($0),"</head>"))>0 {pre=substr($0,1,p-1); if(pre!="") print pre; printf "%s", buf; print substr($0,p); done=1; next} {print}' "$f" > "$f.tmp.$$" && cat "$f.tmp.$$" > "$f" && rm -f "$f.tmp.$$"
        n=$((n+1))
    else
        echo "  пропущен (нет </head>): $f"
    fi
done < <(find "$SITE" -name '*.html' -print0)
rm -f "$SNIP"
echo "Готово: вставлено в $n файл(ов) в $SITE: ${CL:+Clarity }${GA:+GA4 }${GSV:+Search-Console}"
