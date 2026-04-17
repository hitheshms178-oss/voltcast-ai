import math


GRID_TARIFF_INR_PER_KWH = 8.2
CO2_PER_KWH = 0.82
DEFAULT_APPLIANCE = "washing_machine"

APPLIANCE_PROFILES = {
    "washing_machine": {
        "label": "Washing machine",
        "power_kw": 0.9,
        "duration_hours": 2,
        "usual_start_hour": 19,
        "hero_title": "Laundry gets pushed into the solar-rich window.",
        "image": "https://images.pexels.com/photos/19991837/pexels-photo-19991837.jpeg?cs=srgb&dl=pexels-alex-tyson-227557-19991837.jpg&fm=jpg",
    },
    "air_conditioner": {
        "label": "Air conditioner",
        "power_kw": 1.8,
        "duration_hours": 3,
        "usual_start_hour": 20,
        "hero_title": "Cooling shifts away from the evening ramp.",
        "image": "https://images.pexels.com/photos/17159024/pexels-photo-17159024.jpeg?cs=srgb&dl=pexels-joaquin-carfagna-1817169-17159024.jpg&fm=jpg",
    },
    "dishwasher": {
        "label": "Dishwasher",
        "power_kw": 1.4,
        "duration_hours": 2,
        "usual_start_hour": 21,
        "hero_title": "Dish cycles run when the grid is least stressed.",
        "image": "https://images.pexels.com/photos/213162/pexels-photo-213162.jpeg?cs=srgb&dl=pexels-asphotography-213162.jpg&fm=jpg",
    },
    "water_heater": {
        "label": "Water heater",
        "power_kw": 2.2,
        "duration_hours": 1,
        "usual_start_hour": 7,
        "hero_title": "Hot water lands in the cleanest hour of the day.",
        "image": "https://images.pexels.com/photos/9551366/pexels-photo-9551366.jpeg?cs=srgb&dl=pexels-107014568-9551366.jpg&fm=jpg",
    },
    "ev_charger": {
        "label": "EV charger",
        "power_kw": 3.3,
        "duration_hours": 4,
        "usual_start_hour": 20,
        "hero_title": "Charging moves into the midday renewable valley.",
        "image": "https://images.pexels.com/photos/27355836/pexels-photo-27355836.jpeg?cs=srgb&dl=pexels-andersen-ev-1251124834-27355836.jpg&fm=jpg",
    },
}


def _clamp(value, minimum, maximum):
    return max(minimum, min(maximum, value))


def predict_solar_output(cloud_percentage):
    """Estimate solar availability from cloud coverage."""
    cloud_percentage = _clamp(int(cloud_percentage), 0, 100)
    return max(0, 100 - cloud_percentage)


def estimate_voltage(solar_output):
    """Estimate voltage from solar availability against a 230V reference."""
    return round((solar_output / 100) * 230, 1)


def get_recommendation(solar_output):
    """Return appliance guidance based on predicted solar availability."""
    if solar_output > 70:
        return "The cleanest window is open right now for heavy appliances."

    if solar_output > 40:
        return "There is usable renewable power, but the midday window will save more."

    return "Hold flexible loads for later when solar recovers."


def build_energy_snapshot(cloud_percentage):
    solar_output = predict_solar_output(cloud_percentage)
    voltage = estimate_voltage(solar_output)

    return {
        "solar_output": solar_output,
        "voltage": voltage,
        "best_time": get_recommendation(solar_output),
    }


def build_duck_curve(cloud_percentage):
    cloud_percentage = _clamp(int(cloud_percentage), 0, 100)
    solar_multiplier = max(0.18, 1 - (cloud_percentage / 100) * 0.72)
    curve = []

    for hour in range(24):
        solar_output = 160 * math.exp(-0.5 * ((hour - 12) ** 2) / 6) * solar_multiplier
        wind_output = 25 + 15 * math.sin((hour - 2) / 24 * 2 * math.pi)
        renewable = max(0, solar_output + wind_output)
        demand = (
            60
            + 70 * math.exp(-0.5 * ((hour - 8) ** 2) / 3)
            + 110 * math.exp(-0.5 * ((hour - 19) ** 2) / 4)
            + 15 * math.sin((hour / 24) * 2 * math.pi)
        )
        non_renewable = max(0, demand - renewable)

        curve.append(
            {
                "hour": hour,
                "solar": round(solar_output, 1),
                "wind": round(wind_output, 1),
                "renewable": round(renewable, 1),
                "demand": round(demand, 1),
                "non_renewable": round(non_renewable, 1),
            }
        )

    return curve


def _format_hour(hour):
    hour = hour % 24
    suffix = "AM" if hour < 12 else "PM"
    hour_12 = hour % 12 or 12
    return f"{hour_12}:00 {suffix}"


def _format_window(start_hour, duration_hours):
    end_hour = (start_hour + duration_hours) % 24
    return f"{_format_hour(start_hour)} - {_format_hour(end_hour)}"


def _grid_fraction(point):
    if point["demand"] <= 0:
        return 0.0
    return _clamp(point["non_renewable"] / point["demand"], 0.0, 1.0)


def _window_stats(curve, start_hour, duration_hours, power_kw):
    grid_energy = 0.0
    renewable_share = 0.0

    for offset in range(duration_hours):
        point = curve[start_hour + offset]
        grid_fraction = _grid_fraction(point)
        renewable_fraction = 1 - grid_fraction
        grid_energy += power_kw * grid_fraction
        renewable_share += power_kw * renewable_fraction

    total_energy = max(power_kw * duration_hours, 0.01)
    renewable_percent = round((renewable_share / total_energy) * 100)

    return {
        "grid_energy": round(grid_energy, 2),
        "renewable_percent": renewable_percent,
    }


def build_appliance_insights(cloud_percentage):
    curve = build_duck_curve(cloud_percentage)
    insights = {}

    for key, profile in APPLIANCE_PROFILES.items():
        duration = profile["duration_hours"]
        usual_start = profile["usual_start_hour"]
        power_kw = profile["power_kw"]
        latest_start = len(curve) - duration
        candidate_hours = range(5, latest_start + 1)

        scored_windows = [
            (start_hour, _window_stats(curve, start_hour, duration, power_kw))
            for start_hour in candidate_hours
        ]
        best_start, best_stats = min(
            scored_windows,
            key=lambda item: (item[1]["grid_energy"], -item[1]["renewable_percent"], item[0]),
        )
        usual_stats = _window_stats(curve, usual_start, duration, power_kw)

        energy_saved = max(0.12, usual_stats["grid_energy"] - best_stats["grid_energy"])
        money_saved = energy_saved * GRID_TARIFF_INR_PER_KWH
        co2_saved = energy_saved * CO2_PER_KWH
        shift_hours = best_start - usual_start
        shift_text = "the same time as usual" if shift_hours == 0 else f"{abs(shift_hours)}h {'earlier' if shift_hours < 0 else 'later'}"
        shift_summary = (
            "matching the usual slot"
            if shift_hours == 0
            else f"{shift_text} than the usual slot"
        )

        insights[key] = {
            "id": key,
            "label": profile["label"],
            "hero_title": profile["hero_title"],
            "image": profile["image"],
            "duration_hours": duration,
            "power_kw": power_kw,
            "usual_window": _format_window(usual_start, duration),
            "recommended_window": _format_window(best_start, duration),
            "recommended_start_hour": best_start,
            "baseline_start_hour": usual_start,
            "renewable_percent": best_stats["renewable_percent"],
            "energy_saved_kwh": round(energy_saved, 2),
            "money_saved_inr": round(money_saved, 2),
            "co2_saved_kg": round(co2_saved, 2),
            "ai_summary": (
                f"VoltCast moves {profile['label'].lower()} usage to {_format_window(best_start, duration)} "
                f"with about {best_stats['renewable_percent']}% renewable coverage, {shift_summary}."
            ),
        }

    return insights


def _appliance_guidance(query, solar_output):
    heavy_appliances = [
        "washing machine",
        "washer",
        "ev",
        "charger",
        "charging",
        "iron",
        "heater",
        "ac",
        "air conditioner",
        "pump",
        "microwave",
        "oven",
        "dishwasher",
    ]

    if not any(appliance in query for appliance in heavy_appliances):
        return ""

    if solar_output > 70:
        return "Yes, this is a strong solar window for flexible heavy loads."

    if solar_output > 40:
        return "You can run it now, but the midday renewable valley will save more."

    return "I would wait for the cleaner midday window before running that appliance."


def generate_chat_response(query, weather, solar_output, voltage):
    """Return a conversational answer using current computed solar data."""
    normalized_query = query.lower()
    recommendation = get_recommendation(solar_output)
    appliance_answer = _appliance_guidance(normalized_query, solar_output)

    context = (
        f"Based on current weather in {weather['city']}, cloud coverage is "
        f"{weather['cloud_percentage']}% and solar availability is {solar_output}%. "
        f"You can generate approximately {voltage}V."
    )

    if appliance_answer:
        return f"{context} {appliance_answer} {recommendation}"

    if any(word in normalized_query for word in ["power", "available", "voltage", "generate"]):
        return (
            f"{context} That means the system has about {solar_output}% usable solar energy "
            f"available for your home right now."
        )

    if any(word in normalized_query for word in ["best", "time", "when", "electricity", "use"]):
        return f"{context} My recommendation: {recommendation}"

    if any(word in normalized_query for word in ["weather", "temperature", "humidity", "cloud"]):
        return (
            f"The weather in {weather['city']} is {weather['description']} with "
            f"{weather['temperature']} degrees C, {weather['humidity']}% humidity, and "
            f"{weather['cloud_percentage']}% cloud coverage. Solar availability is {solar_output}%."
        )

    return (
        f"{context} {recommendation} You can ask me things like "
        "'Can I run washing machine now?' or 'How much power is available?'"
    )
