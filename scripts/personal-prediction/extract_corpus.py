# Pulls your own writing off the Mac into corpus.json: sent iMessages/SMS,
# Apple Notes text, and contact names. Runs on the Mac and needs Full Disk
# Access. Output stays in WORK_DIR, outside the repository.

import glob
import json
import os
import re
import sqlite3
import zlib

APPLE_EPOCH = 978307200
HOME = os.path.expanduser("~")
MESSAGES_DB = f"{HOME}/Library/Messages/chat.db"
NOTES_DB = f"{HOME}/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
CONTACT_DBS = glob.glob(f"{HOME}/Library/Application Support/AddressBook/**/AddressBook-v22.abcddb", recursive=True)
WORK_DIR = f"{HOME}/Downloads/keyboard-prediction-eval"
CORPUS = f"{WORK_DIR}/corpus.json"
TEXT_REACTION = re.compile(r"^(Loved|Liked|Disliked|Laughed at|Emphasized|Questioned|Reacted .+ to) \u201c")

###############################################################################

def readonly(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)

###############################################################################

def attributed_body_text(blob):
    start = blob.find(b"NSString")
    if start < 0:
        return None
    index = start + len(b"NSString") + 5
    length = blob[index]
    index += 1
    if length == 0x81:
        length = int.from_bytes(blob[index:index + 2], "little")
        index += 2
    elif length == 0x82:
        length = int.from_bytes(blob[index:index + 3], "little")
        index += 3
    return blob[index:index + length].decode("utf-8", errors="replace")

###############################################################################

def messages():
    rows = readonly(MESSAGES_DB).execute(
        "select date, text, attributedBody from message "
        "where is_from_me = 1 and associated_message_type = 0 and item_type = 0 order by date"
    )
    result = []
    agree = disagree = 0
    for date, text, body in rows:
        decoded = attributed_body_text(body) if body else None
        if text and decoded is not None:
            if decoded == text:
                agree += 1
            else:
                disagree += 1
        text = text or decoded
        if not text:
            continue
        text = text.replace("\ufffc", "").strip()
        if not text or TEXT_REACTION.match(text):
            continue
        result.append({"date": date / 1e9 + APPLE_EPOCH, "text": text})
    print(f"messages: {len(result)} kept; attributedBody decoder agrees with text column {agree}/{agree + disagree}")
    return result

###############################################################################

def protobuf_fields(data):
    index = 0
    while index < len(data):
        key, index = varint(data, index)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, index = varint(data, index)
        elif wire == 1:
            value, index = data[index:index + 8], index + 8
        elif wire == 2:
            length, index = varint(data, index)
            value, index = data[index:index + length], index + length
        elif wire == 5:
            value, index = data[index:index + 4], index + 4
        else:
            return
        yield field, value

###############################################################################

def varint(data, index):
    result = shift = 0
    while True:
        byte = data[index]
        index += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, index
        shift += 7

###############################################################################

def field(data, number):
    return next(value for key, value in protobuf_fields(data) if key == number)

###############################################################################

def notes():
    rows = readonly(NOTES_DB).execute(
        "select n.ZDATA, o.ZCREATIONDATE1 from ZICNOTEDATA n join ZICCLOUDSYNCINGOBJECT o on o.Z_PK = n.ZNOTE "
        "where n.ZDATA is not null and n.ZCRYPTOTAG is null and (o.ZMARKEDFORDELETION is null or o.ZMARKEDFORDELETION = 0)"
    )
    result = []
    for data, created in rows:
        document = field(zlib.decompress(data, wbits=47), 2)
        text = field(field(document, 3), 2).decode("utf-8", errors="replace")
        text = text.replace("\ufffc", "").strip()
        if text:
            result.append({"date": (created or 0) + APPLE_EPOCH, "text": text})
    print(f"notes: {len(result)}")
    return result

###############################################################################

def contacts():
    names = set()
    for path in CONTACT_DBS:
        rows = readonly(path).execute("select ZFIRSTNAME, ZLASTNAME, ZNICKNAME, ZORGANIZATION from ZABCDRECORD")
        for row in rows:
            names.update(part for value in row if value for part in value.split() if part)
    print(f"contact name words: {len(names)}")
    return sorted(names)

###############################################################################

def main():
    corpus = {"messages": messages(), "notes": notes(), "contacts": contacts()}
    os.makedirs(WORK_DIR, exist_ok=True)
    with open(CORPUS, "w") as out:
        json.dump(corpus, out)
    os.chmod(CORPUS, 0o600)

###############################################################################

if __name__ == "__main__":
    main()
