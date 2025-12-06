# Tibber Price Forecast

![Tibber Price Forecast](screenshot.png)

Display real-time electricity price forecast and consumption intelligence from [Tibber](https://tibber.com/) on your Tidbyt.

## Features

- 📊 **30-Minute Granularity**: 60 half-hourly bars showing prices from midnight today through tomorrow morning
- 🎨 **Gradient Price Coloring**: Smooth color transitions from green (cheap) to red (expensive) matching the Tibber mobile app
- 💡 **Consumption Intelligence**: Smart efficiency color coding shows when you're using power wisely
- 🔄 **Smart Caching**: Reliable display with automatic fallback if API is temporarily unavailable

## Configuration

### Step 1: Get Your Tibber API Token

1. Visit [Tibber Developer Portal](https://developer.tibber.com/)
2. Log in with your Tibber account
3. Generate a personal access token (it's free!)
4. Copy the token - you'll need it in Step 3

### Step 2: Install the App

1. Open the Tidbyt mobile app on your phone
2. Tap **+** to add a new app
3. Search for "Tibber Price Forecast"
4. Tap to install

### Step 3: Configure Your Token

1. When prompted, paste your Tibber API token
2. The app will automatically load your electricity data
3. Your Tidbyt will start displaying your price forecast!

## What You'll See

### Upper Chart: Price Forecast
Shows electricity prices for the next 30 hours with gradient coloring:
- 🟢 **Green**: Cheapest prices (0-30th percentile)
- 🟡 **Yellow**: Average prices (30-70th percentile)  
- 🔴 **Red**: Most expensive prices (70-100th percentile)

The gradient smoothly transitions through the spectrum, with bright contour lines highlighting price peaks for easy identification.

### Lower Chart: Consumption (Past Hours Only)
Shows your actual electricity usage with intelligent efficiency coloring:
- 🟢 **Green**: Excellent - Low usage or usage during cheap prices
- 🟡 **Yellow**: Moderate efficiency
- 🔴 **Red**: Consider shifting - High usage during expensive prices

Future hours show gray bars since consumption data isn't available yet.

## Requirements

- Active Tibber subscription
- Tibber API token (free from [developer.tibber.com](https://developer.tibber.com/))
- Tidbyt device

## Supported Countries

This app works with Tibber in:
- 🇳🇴 Norway
- 🇸🇪 Sweden
- 🇩🇪 Germany
- 🇳🇱 Netherlands

## Technical Details

- Updates hourly with smart caching
- Uses Tibber's quarter-hourly price API for precise 30-minute intervals
- Consumption data split from hourly to 30-minute slots
- Handles PV systems and grid export (negative consumption)
- Graceful fallback with stale data indicator if API is unavailable

## About

Created by [cruschke](https://github.com/cruschke)

**Links:**
- [Source Code](https://github.com/cruschke/tidbyt-tibber)
- [Developer Documentation](https://github.com/cruschke/tidbyt-tibber/blob/main/README.dev.md)
- [Tibber](https://tibber.com/)
- [Tibber Developer Portal](https://developer.tibber.com/)

## License

Apache-2.0 License - Free to use and modify

---

**Tip**: The app works great for timing energy-intensive tasks like EV charging, washing machines, or dishwashers to run during cheap price periods!
