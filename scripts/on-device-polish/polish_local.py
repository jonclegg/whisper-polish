# Polishes every input with a local GGUF model under llama-server, through the
# app's prompt (or a compact prompt for small models).
#
# Usage: python polish_local.py MODEL.gguf INPUTS.jsonl OUT.jsonl [--prompt app|compact] [--temperature T]

import argparse
import concurrent.futures
import json
import subprocess
import time
import urllib.request

import common
import prompts

PORT = 8091


def wait_for_server(process):
    for _ in range(240):
        if process.poll() is not None:
            raise RuntimeError("llama-server exited")
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=1)
            return
        except Exception:
            time.sleep(0.5)
    raise RuntimeError("llama-server did not start")


def complete(messages, temperature):
    body = {"messages": messages, "temperature": temperature, "max_tokens": 900,
            "chat_template_kwargs": {"enable_thinking": False}}
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=600) as response:
        reply = json.load(response)
    text = reply["choices"][0]["message"]["content"] or ""
    if "</think>" in text:
        text = text.split("</think>", 1)[1]
    return text.strip(), reply["usage"]["completion_tokens"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("inputs")
    parser.add_argument("out")
    parser.add_argument("--prompt", default="app")
    parser.add_argument("--temperature", type=float, default=0.3)
    arguments = parser.parse_args()
    rows = common.read_jsonl(arguments.inputs)
    server = subprocess.Popen(
        ["llama-server", "-m", arguments.model, "--port", str(PORT), "-c", "16384", "-np", "4", "--jinja", "-ngl", "99"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for_server(server)

        def polish(row):
            started = time.time()
            text, tokens = complete(prompts.build(arguments.prompt, row["text"], common.instruction(row)), arguments.temperature)
            return {**row, "output": text, "model": arguments.model.split("/")[-1], "prompt": arguments.prompt,
                    "seconds": round(time.time() - started, 2), "tokens": tokens}

        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(polish, rows))
    finally:
        server.terminate()
        server.wait()
    common.write_jsonl(arguments.out, results)
    print(f"wrote {len(results)} to {arguments.out}")


if __name__ == "__main__":
    main()
