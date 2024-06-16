#!/bin/bash

#### Example secret.txt
## STREET_ID="123456"
## HOUSE="12"
## TG_BOT_ID="bot6191234558:AAGWWpWtZUExAmPlEbpt3WkS8QzdcuQNq2DA"
## TG_CHAT_ID="-1001553812345"
## TG_DIS_NOTIFY="true"
## SLACK_CNANNEL="C02EXAMPLE"
## SLACK_TOKEN="xoxb-2370012345-6315485354321-a8669EiJnp0JExAmPlELwOHg"
####

URL="https://hoe.com.ua/shutdown-events"
POST_DATA="streetId=$STREET_ID&house=$HOUSE"
SUBJECT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTNAME="$(basename "$0" .sh)"
PREV_FILE="$SCRIPT_DIR/${SCRIPTNAME}_lastdata.txt"
LOG_DIR="$SCRIPT_DIR/hoe-check"
LOG_FILE="$LOG_DIR/${SCRIPTNAME}.log"
CURR_DATE="$(date +"%H:%M:%S %d.%m.%Y")"
source "$SCRIPT_DIR/secret.txt"

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

send_message_tg() {
    local message="$1"

    curl -s -o /dev/null \
        --data parse_mode=HTML \
        --data chat_id="${TG_CHAT_ID}" \
        --data disable_notification="${TG_DIS_NOTIFY}" \
        --data text="<b>${SUBJECT} </b>%0A%0A<code>${message}</code>" \
        --request POST "https://api.telegram.org/${TG_BOT_ID}/sendMessage"
}

send_message_slack() {
    local message="$1"

    if [ -z "$SUBJECT" ]; then
        SUBJECT=""
    else
        SUBJECT="*$SUBJECT*"
    fi

    curl -s -o /dev/null \
        -H "Content-type: application/json" \
    --data "{\"channel\":\"$SLACK_CNANNEL\",\"blocks\":[{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":\"${SUBJECT}\n\`\`\`${message}\`\`\`\"}}]}" \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -X POST https://slack.com/api/chat.postMessage
}

send_message() {
        if [ "$1" == "TG" ]; then
                send_message_tg "$2"
        elif [ "$1" == "SLACK" ]; then
                send_message_slack "$2"
        else
                exit 1
        fi
}

save_log() {
        echo "$CURR_DATE" >> "$LOG_FILE"
        echo "$html_content" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
}

html_content=$(curl -s "${URL}" -H 'x-requested-with: XMLHttpRequest' --data-raw "${POST_DATA}")

parsed_text=$(echo "$html_content" | sed -n '
    /<tr>/ {
        n
        s/.*<td>\(.*\)<\/td>.*/Вид робіт: \1/p
        n
        s/.*<td>\(.*\)<\/td>.*/Тип відключення: \1/p
        n
        s/.*<td class="text-center">\([^<]*\)<\/td>.*/Черга: \1/p
        n
        s/.*<td class="text-right">\([^<]*\)<\/td>.*/Початок: \1/p
        n
        s/.*<td class="text-right">\([^<]*\)<\/td>.*/Кінець: \1/p
    }
    ')

parsed_text=$(echo "$parsed_text" | awk '{print} $0 ~ /^Кінець:/ {print ""}')

previous_text=$(cat $PREV_FILE 2>/dev/null)

if [[ "$html_content" != "$previous_text" ]]; then

    echo "$html_content" > $PREV_FILE
    save_log

        if [[ -n "$parsed_text" && $(echo "$html_content" | grep -i "Вид робіт") ]]; then
                SUBJECT="З'явились погодинні відключення!"
                send_message "$1" "$parsed_text"
        elif [[ $(echo "$html_content" | grep -i "відсутнє зареєстроване відключення") ]]; then
                send_message "$1" "Погодинних відключень немає!"
        else
                send_message "$1" "Помилка отримання даних."
        fi
fi
