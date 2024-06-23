#!/bin/bash

# Example run script: "bash HoeShutdownNotifier.sh home"
#### Example file "home"
## SEND_TO="TG"
## STREET_ID="123456"
## HOUSE="12"
## TG_BOT_ID="bot6191234558:AAGWWpWtZUExAmPlEbpt3WkS8QzdcuQNq2DA"
## TG_CHAT_ID="-1001553812345"
## TG_DIS_NOTIFY="true"
## SLACK_CNANNEL="C02EXAMPLE"
## SLACK_TOKEN="xoxb-2370012345-6315485354321-a8669EiJnp0JExAmPlELwOHg"
## ENABLE_LOG="yes"
####

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_FILE="$1"
source "$SCRIPT_DIR/$CFG_FILE"
URL="https://hoe.com.ua/shutdown-events"
POST_DATA="streetId=$STREET_ID&house=$HOUSE"
SUBJECT=""
SCRIPTNAME="$(basename "$0" .sh)"
PREV_FILE="$SCRIPT_DIR/${SCRIPTNAME}_lastdata_$CFG_FILE.txt"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/${SCRIPTNAME}_$CFG_FILE.log"
CURR_DATE="$(date +"%H:%M:%S %d.%m.%Y")"
ENABLE_LOG="yes"

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
        if [ "$SEND_TO" == "TG" ]; then
                send_message_tg "$2"
        elif [ "$SEND_TO" == "SLACK" ]; then
                send_message_slack "$2"
        else
                exit 1
        fi
}

save_log() {
	if [ "$ENABLE_LOG" == "yes" ]; then
        echo "$CURR_DATE" >> "$LOG_FILE"
        echo "$html_content" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
	fi
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
    if [[ -n "$parsed_text" && $(echo "$html_content" | grep -i "Вид робіт") ]]; then
        if grep -qi "Вид робіт" "$PREV_FILE"; then
            SUBJECT="Змінились погодинні відключення!"
        else
            SUBJECT="З'явились погодинні відключення!"
        fi
        send_message "$1" "$parsed_text"
    elif [[ $(echo "$html_content" | grep -i "відсутнє зареєстроване відключення") ]]; then
        send_message "$1" "Погодинних відключень немає!"
    else
        send_message "$1" "Помилка отримання даних."
    fi
    echo "$html_content" > $PREV_FILE
    save_log
fi
