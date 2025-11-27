#!/usr/bin/env python3
import os
import re
import time
import tempfile
import requests
from datetime import datetime
from pathlib import Path
from bs4 import BeautifulSoup
from slack_sdk import WebClient as SlackClient
from telegram import Bot as TelegramBot
from dotenv import dotenv_values

# --- Конфігурація ---
SCRIPT_DIR = Path(__file__).resolve().parent
CFG_FILE = os.environ.get("CONFIG", "home")
CFG = dotenv_values(SCRIPT_DIR / CFG_FILE)

SEND_TO = CFG.get("SEND_TO", "TG")
STREET_ID = CFG.get("STREET_ID")
HOUSE = CFG.get("HOUSE")
TG_BOT_ID = CFG.get("TG_BOT_ID")
TG_CHAT_ID = CFG.get("TG_CHAT_ID")
TG_DIS_NOTIFY = CFG.get("TG_DIS_NOTIFY", "true").lower() == "true"
SLACK_TOKEN = CFG.get("SLACK_TOKEN")
SLACK_CHANNEL = CFG.get("SLACK_CHANNEL")
ENABLE_LOG = CFG.get("ENABLE_LOG", "no").lower() == "yes"
SEND_GRAPHS = CFG.get("SEND_GRAPHS", "no").lower() == "yes"
SEND_SHUTDOWN_EVENTS = CFG.get("SEND_SHUTDOWN_EVENTS", "yes").lower() == "yes"
RETRIES = int(CFG.get("RETRIES", 5))
DELAY = int(CFG.get("DELAY", 10))

# --- Сталі ---
DOMAIN = "https://hoe.com.ua"
URL = f"{DOMAIN}/shutdown-events"
PAGE_URL = f"{DOMAIN}/page/pogodinni-vidkljuchennja"
POST_DATA = {"streetId": STREET_ID, "house": HOUSE}
EXPECTED_IMAGE_ALT_PATTERN = r"(ГПВ|gpv)"
SUBJECT = ""
LOG_DIR = SCRIPT_DIR / "logs"
LOG_FILE = LOG_DIR / f"HoeShutdownNotifier_{CFG_FILE}.log"
PREV_FILE = SCRIPT_DIR / f"HoeShutdownNotifier_lastdata_{CFG_FILE}.txt"
URL_FILE = SCRIPT_DIR / f"last_image_url_{CFG_FILE}.txt"
CURR_DATE = datetime.now().strftime("%H:%M:%S %d.%m.%Y")

# --- Ініціалізація ---
LOG_DIR.mkdir(parents=True, exist_ok=True)
slack = SlackClient(token=SLACK_TOKEN) if SLACK_TOKEN else None
tg = TelegramBot(token=TG_BOT_ID.split("bot", 1)[-1]) if TG_BOT_ID else None


def normalize(text: str) -> str:
    return "\n".join(line.strip() for line in text.strip().splitlines() if line.strip())


def send_message(text: str):
    global SUBJECT
    if SEND_TO == "TG":
        tg.send_message(
            chat_id=TG_CHAT_ID,
            text=(f"<b>{SUBJECT}</b>\n\n" if SUBJECT else "") + f"<code>{text}</code>",
            parse_mode="HTML",
            disable_notification=TG_DIS_NOTIFY,
        )
    elif SEND_TO == "SLACK":
        blocks = [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (f"*{SUBJECT}*\n" if SUBJECT else "") + f"```{text}```",
                },
            }
        ]
        slack.chat_postMessage(
            channel=SLACK_CHANNEL,
            text=f"{SUBJECT} {text[:100]}" if SUBJECT else text[:100],
            blocks=blocks,
        )


def send_image(file_path: str):
    if SEND_TO == "TG":
        with open(file_path, "rb") as f:
            tg.send_photo(chat_id=TG_CHAT_ID, photo=f)
    elif SEND_TO == "SLACK":
        slack.files_upload_v2(file=file_path, channel=SLACK_CHANNEL)


def log_content(content: str):
    if ENABLE_LOG:
        with open(LOG_FILE, "a") as log:
            log.write(f"{CURR_DATE}\n{content}\n\n")


def fetch_with_retries(url, data):
    for i in range(RETRIES):
        try:
            r = requests.post(
                url,
                data=data,
                headers={"x-requested-with": "XMLHttpRequest"},
                timeout=15,
            )
            if r.text.strip():
                return r.text
        except Exception:
            pass
        print(
            f"[{datetime.now().strftime('%H:%M:%S')}] Спроба {i+1}/{RETRIES} не вдалася. Очікую {DELAY}с..."
        )
        time.sleep(DELAY)
    return "__FETCH_FAILED__"


def sending_graphs():
    if not SEND_GRAPHS:
        return
    try:
        page = requests.get(PAGE_URL).text
        soup = BeautifulSoup(page, "html.parser")
        img = next(
            (
                i
                for i in soup.find_all("img")
                if re.search(EXPECTED_IMAGE_ALT_PATTERN, i.get("alt", ""), re.I)
            ),
            None,
        )
        if not img:
            return
        image_url = DOMAIN + img["src"]
        prev_url = URL_FILE.read_text().strip() if URL_FILE.exists() else ""
        if image_url == prev_url:
            return
        with tempfile.NamedTemporaryFile(delete=False, suffix=".png") as tmp:
            img_data = requests.get(image_url).content
            tmp.write(img_data)
            send_image(tmp.name)
        URL_FILE.write_text(image_url)
    except Exception as e:
        print("Помилка при завантаженні графіка:", e)


def main():
    sending_graphs()
    if not SEND_SHUTDOWN_EVENTS:
        return

    html = fetch_with_retries(URL, POST_DATA)
    if html == "__FETCH_FAILED__":
        send_message(f"Сайт hoe.com.ua недоступний. {RETRIES} спроб по {DELAY}с.")
        return

    soup = BeautifulSoup(html, "html.parser")

    # ==============================
    # 📌 АВТОМАТИЧНИЙ ПАРСЕР ТАБЛИЦІ
    # ==============================

    table = soup.find("table")
    parsed = []

    if table:
        # 1️⃣ Заголовки
        headers = [th.get_text(strip=True) for th in table.find("thead").find_all("th")]

        # 2️⃣ Рядки
        for row in table.find("tbody").find_all("tr"):
            cells = [td.get_text(strip=True) for td in row.find_all("td")]
            if len(cells) != len(headers):
                continue
            item = dict(zip(headers, cells))

            block = "\n".join(f"{k}: {v}" for k, v in item.items())
            parsed.append(block)

    # 3️⃣ Формуємо текст повідомлення
    message = normalize("\n\n".join(parsed))
    prev_text = PREV_FILE.read_text().strip() if PREV_FILE.exists() else ""

    # ==============================
    # 🔔 Логіка відправки повідомлень
    # ==============================

    if message and message != prev_text:
        global SUBJECT
        SUBJECT = (
            "Змінились погодинні відключення!"
            if prev_text and prev_text != "NO_OUTAGES"
            else "З'явились погодинні відключення!"
        )
        send_message(message)
        PREV_FILE.write_text(message)
        log_content(message)
        return

    if not message and "відключ" in html.lower() and prev_text != "NO_OUTAGES":
        SUBJECT = ""
        send_message("Погодинних відключень немає!")
        PREV_FILE.write_text("NO_OUTAGES")
        log_content("NO_OUTAGES")
        return

    print("ℹ️ Дані не змінились — повідомлення не надсилаю.")


if __name__ == "__main__":
    main()
