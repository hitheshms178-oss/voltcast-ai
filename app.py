import streamlit as st
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

st.set_page_config(layout="wide")

# ---------- STYLE ----------
st.markdown("""
<style>
body {
    background-color: #0e1117;
}
.title {
    font-size: 42px;
    font-weight: bold;
    color: #00f5d4;
}
.subtitle {
    color: #aaaaaa;
}
.card {
    background-color: #1c1f26;
    padding: 25px;
    border-radius: 15px;
    text-align: center;
}
.metric {
    font-size: 30px;
    font-weight: bold;
    color: #00f5d4;
}
.label {
    color: #bbbbbb;
}
</style>
""", unsafe_allow_html=True)

# ---------- HEADER ----------
st.markdown("<div class='title'>⚡ Powered by VoltCast</div>", unsafe_allow_html=True)
st.markdown("<div class='subtitle'>AI Smart Energy Optimizer</div>", unsafe_allow_html=True)

# ---------- APPLIANCE ----------
st.write("### 🔌 Select Your Appliance")

appliance = st.selectbox(
    "",
    ["Washing Machine", "Dishwasher", "EV Charging", "Air Conditioner", "Water Pump"]
)

# ---------- DATA ----------
hours = np.arange(24)

solar = 160 * np.exp(-0.5 * (hours - 12)**2 / 6)
wind = 25 + 15 * np.sin((hours - 2) / 24 * 2 * np.pi)

renewable = np.maximum(0, solar + wind)

demand = (
    60 +
    70 * np.exp(-0.5 * (hours - 8)**2 / 3) +
    110 * np.exp(-0.5 * (hours - 19)**2 / 4)
)

grid = np.maximum(0, demand - renewable)

df = pd.DataFrame({
    "hour": hours,
    "renewable": renewable,
    "demand": demand,
    "grid": grid
})

# ---------- AI ----------
best_hour = int(df["renewable"].idxmax())

st.write("### 🤖 AI Recommendation")
st.success(f"Use your **{appliance} at {best_hour}:00 hours** ⚡")

# ---------- METRICS ----------
st.write("### 📊 Impact")

col1, col2, col3 = st.columns(3)

energy_saved = df["renewable"].sum()
money_saved = energy_saved * 0.35
co2_saved = energy_saved * 0.8

with col1:
    st.markdown(f"<div class='card'><div class='metric'>{energy_saved:.0f}</div><div class='label'>Energy Saved</div></div>", unsafe_allow_html=True)

with col2:
    st.markdown(f"<div class='card'><div class='metric'>₹{money_saved:.0f}</div><div class='label'>Money Saved</div></div>", unsafe_allow_html=True)

with col3:
    st.markdown(f"<div class='card'><div class='metric'>{co2_saved:.0f} kg</div><div class='label'>CO₂ Reduced</div></div>", unsafe_allow_html=True)

# ---------- GRAPH ----------
st.write("### 🦆 Duck Curve")

fig, ax = plt.subplots()

ax.plot(df["hour"], df["demand"], label="Demand")
ax.plot(df["hour"], df["renewable"], label="Renewable")

ax.set_xlabel("Hour")
ax.set_ylabel("Energy")
ax.legend()

st.pyplot(fig)