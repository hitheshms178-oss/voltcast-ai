import os
import json
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from model import generate_chat_response, get_recommendation


DEFAULT_MODEL = "gemini-2.5-flash"
GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"


def _load_local_env():
    env_path = Path(__file__).with_name(".env")
    if not env_path.exists():
        return

    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()

        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")

        if key and key not in os.environ:
            os.environ[key] = value


_load_local_env()


def _local_fallback(query, weather, solar_output, voltage, reason):
    fallback = generate_chat_response(query, weather, solar_output, voltage)
    return {
        "response": f"{fallback}\n\nAI module note: {reason}",
        "mode": "local-fallback",
        "model": "rule-based",
    }


def _extract_gemini_text(data):
    candidates = data.get("candidates", [])
    if not candidates:
        return ""

    parts = candidates[0].get("content", {}).get("parts", [])
    return "\n".join(part.get("text", "") for part in parts).strip()


def generate_ai_response(query, weather, solar_output, voltage):
    """Generate a real LLM response with Gemini, falling back locally if needed."""
    api_key = os.getenv("GEMINI_API_KEY", "").strip()

    if not api_key:
        return _local_fallback(
            query,
            weather,
            solar_output,
            voltage,
            "set GEMINI_API_KEY to enable real Gemini AI responses.",
        )

    model = os.getenv("GEMINI_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL
    recommendation = get_recommendation(solar_output)

    instructions = (
        "You are VoltCast, a helpful conversational AI assistant for a solar "
        "energy dashboard. Answer naturally like ChatGPT: concise, practical, "
        "and friendly. Use the provided live solar and weather data as truth. "
        "Never invent readings. For appliance questions, give direct advice "
        "using solar availability, estimated voltage, and the recommendation. "
        "Mention that safety-critical electrical decisions should follow "
        "professional guidance."
    )

    prompt = (
        "Current VoltCast data:\n"
        f"- City: {weather['city']}\n"
        f"- Weather: {weather['description']}\n"
        f"- Temperature: {weather['temperature']} degrees C\n"
        f"- Humidity: {weather['humidity']}%\n"
        f"- Cloud coverage: {weather['cloud_percentage']}%\n"
        f"- Solar availability: {solar_output}%\n"
        f"- Estimated voltage: {voltage}V\n"
        f"- Recommendation: {recommendation}\n\n"
        f"User question: {query}"
    )

    body = {
        "systemInstruction": {
            "parts": [{"text": instructions}],
        },
        "contents": [
            {
                "role": "user",
                "parts": [{"text": prompt}],
            }
        ],
        "generationConfig": {
            "temperature": 0.7,
            "maxOutputTokens": 360,
        },
    }

    request = Request(
        GEMINI_ENDPOINT.format(model=model),
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        },
        method="POST",
    )

    try:
        with urlopen(request, timeout=20) as response:
            data = json.loads(response.read().decode("utf-8"))
            text = _extract_gemini_text(data)
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
        return _local_fallback(
            query,
            weather,
            solar_output,
            voltage,
            f"Gemini request failed, so I used the local fallback. Details: {exc}",
        )

    if not text:
        return _local_fallback(
            query,
            weather,
            solar_output,
            voltage,
            "Gemini returned no text, so I used the local fallback.",
        )

    return {
        "response": text,
        "mode": "gemini",
        "model": model,
    }


generate_openai_response = generate_ai_response
