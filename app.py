import os
import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import urlopen

from flask import Flask, Response, jsonify, render_template, request

from ai_service import generate_ai_response
from model import (
    APPLIANCE_PROFILES,
    DEFAULT_APPLIANCE,
    build_appliance_insights,
    build_duck_curve,
    build_energy_snapshot,
)


app = Flask(__name__)

OPENWEATHER_URL = "https://api.openweathermap.org/data/2.5/weather"
DEFAULT_CITY = os.getenv("DEFAULT_CITY", "New Delhi")


def fetch_weather(city):
    """Fetch current weather from OpenWeather, with demo data as a fallback."""
    api_key = os.getenv("OPENWEATHER_API_KEY", "").strip()

    if not api_key:
        return {
            "city": city,
            "temperature": 31,
            "cloud_percentage": 25,
            "humidity": 48,
            "description": "demo clear sky",
            "icon": "01d",
            "source": "Demo data - set OPENWEATHER_API_KEY for live weather",
        }

    query = urlencode({"q": city, "appid": api_key, "units": "metric"})
    url = f"{OPENWEATHER_URL}?{query}"

    try:
        with urlopen(url, timeout=8) as response:
            data = response.read()
    except (HTTPError, URLError, TimeoutError) as exc:
        return {
            "city": city,
            "temperature": 31,
            "cloud_percentage": 25,
            "humidity": 48,
            "description": "fallback clear sky",
            "icon": "01d",
            "source": f"Fallback data - OpenWeather request failed: {exc}",
        }

    weather = json.loads(data.decode("utf-8"))
    description = "current weather"
    icon = "01d"
    if weather.get("weather"):
        description = weather["weather"][0].get("description", description)
        icon = weather["weather"][0].get("icon", icon)

    return {
        "city": weather.get("name", city),
        "temperature": round(weather.get("main", {}).get("temp", 0), 1),
        "cloud_percentage": int(weather.get("clouds", {}).get("all", 0)),
        "humidity": int(weather.get("main", {}).get("humidity", 0)),
        "description": description,
        "icon": icon,
        "source": "Live OpenWeather data",
    }


def build_dashboard_data(city):
    weather = fetch_weather(city)
    snapshot = build_energy_snapshot(weather["cloud_percentage"])
    appliance_insights = build_appliance_insights(weather["cloud_percentage"])
    selected_appliance = request.args.get("appliance", DEFAULT_APPLIANCE).strip() or DEFAULT_APPLIANCE

    if selected_appliance not in APPLIANCE_PROFILES:
        selected_appliance = DEFAULT_APPLIANCE

    return {
        "weather": weather,
        "solar": snapshot["solar_output"],
        "voltage": snapshot["voltage"],
        "recommendation": snapshot["best_time"],
        "status": "ON" if snapshot["solar_output"] > 70 else "OFF",
        "duck_curve": build_duck_curve(weather["cloud_percentage"]),
        "appliance_options": [
            {"id": key, "label": profile["label"]}
            for key, profile in APPLIANCE_PROFILES.items()
        ],
        "appliance_insights": appliance_insights,
        "selected_appliance": selected_appliance,
    }


@app.route("/")
def dashboard():
    city = request.args.get("city", DEFAULT_CITY).strip() or DEFAULT_CITY
    data = build_dashboard_data(city)
    return render_template("index.html", data=data)


@app.route("/status")
def status():
    city = request.args.get("city", DEFAULT_CITY).strip() or DEFAULT_CITY
    data = build_dashboard_data(city)
    return Response(data["status"], mimetype="text/plain")


@app.route("/chat", methods=["POST"])
def chat():
    payload = request.get_json(silent=True) or {}
    query = str(payload.get("query", "")).strip()
    city = str(payload.get("city", DEFAULT_CITY)).strip() or DEFAULT_CITY

    if not query:
        return jsonify({"response": "Ask me about solar output, voltage, or appliances."})

    data = build_dashboard_data(city)
    ai_result = generate_ai_response(
        query,
        data["weather"],
        data["solar"],
        data["voltage"],
    )

    return jsonify(
        {
            "response": ai_result["response"],
            "ai_mode": ai_result["mode"],
            "model": ai_result["model"],
            "solar": data["solar"],
            "voltage": data["voltage"],
            "status": data["status"],
            "recommendation": data["recommendation"],
            "weather": data["weather"],
        }
    )


if __name__ == "__main__":
    app.run(debug=True)
