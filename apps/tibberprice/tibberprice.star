"""
Tibber Price Forecast App for Tidbyt

Displays hourly electricity price forecast from Tibber with color-coded bars.

Author: cruschke
Repository: https://github.com/cruschke/tidbyt-tibber
"""

load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

# Constants
TIBBER_API_URL = "https://api.tibber.com/v1-beta/gql"
TIBBER_DEMO_TOKEN = "3A77EECF61BD445F47241A5A36202185C35AF3AF58609E19B53F3A8872AD7BE1-1"
CACHE_TTL_FRESH = 3600  # 1 hour
CACHE_TTL_STALE = 21600  # 6 hours

# Color scheme (Tibber's official colors)
COLOR_CHEAP = "#00D88A"  # Green
COLOR_NORMAL = "#FFCC00"  # Yellow
COLOR_EXPENSIVE = "#FF9500"  # Orange
COLOR_VERY_EXPENSIVE = "#FF3B30"  # Red
COLOR_UNKNOWN = "#808080"  # Gray fallback

def build_tibber_query():
    """
    Build GraphQL query for Tibber API.

    Requests quarter-hourly (15-minute) prices and hourly consumption data.
    - Prices: QUARTER_HOURLY resolution (96 entries per day)
    - Consumption: HOURLY resolution (24 entries per day)

    Test case:
    - Expected: Query contains "priceInfo(resolution: QUARTER_HOURLY)"
    - Expected: Query contains "consumption(resolution: HOURLY, last: 24)"
    - Expected: Query includes nodes { from, to, consumption, consumptionUnit }
    - Note: consumption is on homes level, not currentSubscription level

    Returns:
        String containing GraphQL query
    """
    return """{
  viewer {
    homes {
      currentSubscription {
        priceInfo(resolution: QUARTER_HOURLY) {
          today {
            total
            level
            startsAt
          }
          tomorrow {
            total
            level
            startsAt
          }
        }
      }
      consumption(resolution: HOURLY, last: 24) {
        nodes {
          from
          to
          consumption
          consumptionUnit
        }
      }
    }
  }
}"""

def fetch_tibber_prices(api_token):
    """
    Fetch price data from Tibber GraphQL API.

    Args:
        api_token: Tibber API authentication token

    Returns:
        Dict with structure:
        {
            "success": bool,
            "data": dict or None,
            "error_code": str or None,
            "error_message": str or None
        }
    """

    # Build request
    query = build_tibber_query()
    headers = {
        "Authorization": "Bearer " + api_token,
        "Content-Type": "application/json",
    }
    body = json.encode({"query": query})

    # Make API request
    response = http.post(
        url = TIBBER_API_URL,
        headers = headers,
        body = body,
        ttl_seconds = 0,  # Don't cache HTTP requests (we have our own caching)
    )

    # Handle HTTP errors
    if response.status_code == 401:
        return {
            "success": False,
            "data": None,
            "error_code": "unauthorized",
            "error_message": "Invalid API token",
        }
    elif response.status_code == 429:
        return {
            "success": False,
            "data": None,
            "error_code": "rate_limited",
            "error_message": "Rate limit exceeded",
        }
    elif response.status_code >= 500:
        return {
            "success": False,
            "data": None,
            "error_code": "server_error",
            "error_message": "Tibber API server error",
        }
    elif response.status_code != 200:
        return {
            "success": False,
            "data": None,
            "error_code": "unknown",
            "error_message": "HTTP " + str(response.status_code),
        }

    # Parse response
    data = response.json()

    # Check for GraphQL errors
    if data.get("errors"):
        error_msg = data["errors"][0].get("message", "Unknown GraphQL error")
        return {
            "success": False,
            "data": None,
            "error_code": "graphql_error",
            "error_message": error_msg,
        }

    # Extract price data with safe navigation
    if not data.get("data"):
        return {
            "success": False,
            "data": None,
            "error_code": "parse_error",
            "error_message": "No data in response",
        }

    viewer = data["data"].get("viewer")
    if not viewer:
        return {
            "success": False,
            "data": None,
            "error_code": "parse_error",
            "error_message": "No viewer in response",
        }

    homes = viewer.get("homes")
    if not homes or len(homes) == 0:
        return {
            "success": False,
            "data": None,
            "error_code": "no_homes",
            "error_message": "No homes found in Tibber account",
        }

    subscription = homes[0].get("currentSubscription")
    if not subscription:
        return {
            "success": False,
            "data": None,
            "error_code": "parse_error",
            "error_message": "No subscription found",
        }

    price_info = subscription.get("priceInfo")
    if not price_info:
        return {
            "success": False,
            "data": None,
            "error_code": "parse_error",
            "error_message": "No price info found",
        }

    # Extract consumption data from homes level (optional)
    consumption_data = homes[0].get("consumption")

    return {
        "success": True,
        "data": {
            "priceInfo": price_info,
            "consumption": consumption_data,
        },
        "error_code": None,
        "error_message": None,
    }

def get_cache_key(api_token):
    """
    Generate cache key from API token.

    Args:
        api_token: API token string

    Returns:
        Cache key string
    """

    # Use hash to avoid storing token in cache key
    # Starlark doesn't have hash(), so use first/last chars as simple key
    if len(api_token) > 8:
        key_part = api_token[:4] + api_token[-4:]
    else:
        key_part = api_token
    return "tibber:prices:" + key_part

def get_cached_prices(api_token):
    """
    Get prices with dual-cache strategy (fresh + stale fallback).

    Args:
        api_token: Tibber API token

    Returns:
        Dict with structure:
        {
            "success": bool,
            "data": dict or None,
            "cache_status": "fresh" | "cached" | "stale" | "error",
            "error_code": str or None,
            "error_message": str or None
        }
    """
    cache_key = get_cache_key(api_token)
    stale_key = cache_key + ":stale"

    # Try fresh cache first
    cached_data = cache.get(cache_key)
    if cached_data:
        data = json.decode(cached_data)
        return {
            "success": True,
            "data": data,
            "cache_status": "cached",
            "error_code": None,
            "error_message": None,
        }

    # Cache miss - fetch from API
    result = fetch_tibber_prices(api_token)

    if result["success"]:
        # Cache the successful result
        data_json = json.encode(result["data"])
        cache.set(cache_key, data_json, ttl_seconds = CACHE_TTL_FRESH)
        cache.set(stale_key, data_json, ttl_seconds = CACHE_TTL_STALE)

        return {
            "success": True,
            "data": result["data"],
            "cache_status": "fresh",
            "error_code": None,
            "error_message": None,
        }

    # API failed - try stale cache
    stale_data = cache.get(stale_key)
    if stale_data:
        data = json.decode(stale_data)
        return {
            "success": True,
            "data": data,
            "cache_status": "stale",
            "error_code": None,
            "error_message": None,
        }

    # No cache available - return error
    return {
        "success": False,
        "data": None,
        "cache_status": "error",
        "error_code": result["error_code"],
        "error_message": result["error_message"],
    }

def calculate_current_slot(timezone):
    """
    Calculate current 30-minute slot index (0-47) based on time.

    Slot mapping:
    - Slot 0: 00:00-00:30
    - Slot 1: 00:30-01:00
    - Slot 28: 14:00-14:30
    - Slot 29: 14:30-15:00
    - Slot 47: 23:30-00:00

    Args:
        timezone: Timezone string for time.now()

    Returns:
        Slot index (0-47)

    Examples:
        14:25 → slot 28 (14*2 + 0)
        14:35 → slot 29 (14*2 + 1)
    """
    now = time.now().in_location(timezone)
    hour = now.hour
    minute = now.minute

    # Calculate slot: hour * 2 + (1 if minute >= 30 else 0)
    slot = hour * 2
    if minute >= 30:
        slot = slot + 1

    return slot

def slot_to_hour_minute(slot):
    """
    Convert slot index (0-47) to (hour, minute) tuple.

    Args:
        slot: Slot index (0-47)

    Returns:
        Tuple of (hour, minute) where minute is 0 or 30

    Examples:
        0 → (0, 0)
        1 → (0, 30)
        28 → (14, 0)
        29 → (14, 30)
        47 → (23, 30)
    """
    hour = slot // 2
    minute = 0 if slot % 2 == 0 else 30
    return (hour, minute)

def hour_minute_to_slot(hour, minute):
    """
    Convert hour and minute to slot index (0-47).

    Args:
        hour: Hour (0-23)
        minute: Minute (0-59)

    Returns:
        Slot index (0-47)

    Examples:
        (14, 0) → 28
        (14, 25) → 28
        (14, 30) → 29
        (14, 45) → 29
    """
    slot = hour * 2
    if minute >= 30:
        slot = slot + 1
    return slot

def parse_time_from_timestamp(timestamp):
    """
    Extract hour and minute from ISO 8601 timestamp.

    Args:
        timestamp: ISO 8601 string like "2025-12-05T14:30:00+01:00"

    Returns:
        Tuple of (hour, minute) as integers

    Examples:
        "2025-12-05T14:00:00+01:00" → (14, 0)
        "2025-12-05T14:30:00+01:00" → (14, 30)
    """

    # Parse timestamp - format: YYYY-MM-DDTHH:MM:SS+TZ
    parts = timestamp.split("T")
    if len(parts) < 2:
        return (0, 0)

    time_parts = parts[1].split(":")
    if len(time_parts) < 2:
        return (0, 0)

    hour = int(time_parts[0])
    minute = int(time_parts[1])
    return (hour, minute)

def parse_hour_from_timestamp(timestamp):
    """
    Extract hour from ISO 8601 timestamp.
    DEPRECATED: Use parse_time_from_timestamp() for new code.

    Args:
        timestamp: ISO 8601 string like "2025-12-05T14:00:00+01:00"

    Returns:
        Hour as integer (0-23)
    """
    hour, _ = parse_time_from_timestamp(timestamp)
    return hour

def parse_price_point(raw_point):
    """
    Parse a single quarter-hourly price point into a 30-minute slot entry.

    Tibber API provides 15-minute resolution (96 entries/day) via QUARTER_HOURLY.
    We select only :00 and :30 minute entries to create 48 half-hourly slots.

    Args:
        raw_point: Dict with keys: total, level, startsAt

    Returns:
        Dict or None:
        - Dict with slot data if minute is 0 or 30
        - None if minute is 15 or 45 (filtered out)

    Example:
        Input: {"total": 0.25, "level": "CHEAP", "startsAt": "2025-12-05T14:00:00+01:00"}
        Output: {"price": 0.25, "level": "CHEAP", "slot": 28, "hour": 14, "minute": 0}

        Input: {"total": 0.27, "level": "CHEAP", "startsAt": "2025-12-05T14:15:00+01:00"}
        Output: None (filtered - we only want :00 and :30)
    """
    hour, minute = parse_time_from_timestamp(raw_point["startsAt"])

    # Only process :00 and :30 entries (skip :15 and :45 for 30-minute granularity)
    if minute not in [0, 30]:
        return None

    price = raw_point["total"]
    level = raw_point["level"]
    slot = hour * 2 + (1 if minute >= 30 else 0)

    return {
        "price": price,
        "level": level,
        "slot": slot,
        "hour": hour,
        "minute": minute,
    }

def parse_tibber_response(response_data):
    """
    Parse Tibber API response into forecast data structure.

    Processes quarter-hourly price data (96 entries) and selects only
    :00 and :30 entries to create 48 half-hourly slots.

    Test cases:
    - Input: response_data with priceInfo (today/tomorrow) and consumption
    - Expected: Returns dict with "prices" (48 slots from 96 quarter-hourly) and "currency" keys
    - Input: response_data with consumption nodes
    - Expected: Returns dict with "consumption" key mapping slot → kWh
    - Edge case: Empty consumption array returns empty dict

    Args:
        response_data: Dict with keys: priceInfo, consumption (optional)

    Returns:
        Dict with structure:
        {
            "prices": [{"price": float, "level": str, "slot": int, "hour": int, "minute": int}],
            "currency": str,
            "consumption": {slot: kWh_value, ...}
        }
    """
    prices = []

    # Extract priceInfo from response_data
    price_info = response_data.get("priceInfo", response_data)

    # Parse today's quarter-hourly prices and filter to 30-minute slots
    # API returns 96 entries (15-min), we select only :00 and :30 → 48 slots
    if price_info.get("today"):
        for point in price_info["today"]:
            # parse_price_point returns dict or None (filters :15 and :45 entries)
            slot_data = parse_price_point(point)
            if slot_data:  # Only add if not filtered out
                prices.append(slot_data)

    # Parse tomorrow's prices with offset slots (48-95)
    # This allows showing a rolling 60-slot window that spans into tomorrow
    if price_info.get("tomorrow"):
        for point in price_info["tomorrow"]:
            slot_data = parse_price_point(point)
            if slot_data:
                # Offset tomorrow's slots by 48 to continue from today
                slot_data["slot"] = slot_data["slot"] + 48
                prices.append(slot_data)

    # Parse consumption data from top level
    consumption_dict = parse_consumption_data(response_data.get("consumption"))

    return {
        "prices": prices,
        "currency": "NOK",  # Default, could be detected from first home
        "consumption": consumption_dict,
    }

def parse_consumption_data(consumption_response):
    """
    Parse consumption data from Tibber API response.

    Converts 24 hourly consumption values into 48 half-hourly slots
    by dividing each hour's consumption equally between the two 30-minute periods.

    Test cases:
    - Input: 24 consumption nodes with ISO timestamps
    - Expected: Returns dict mapping slot (0-47) → kWh value (hourly/2)
    - Edge case: Empty consumption array returns {}
    - Edge case: Malformed timestamps returns {}
    - Example: Input "2025-12-05T14:00:00.000+01:00" with 1.2 kWh
               → slot 28: 0.6 kWh, slot 29: 0.6 kWh

    Args:
        consumption_response: Dict with "nodes" array or None

    Returns:
        Dict mapping slot (0-47) to consumption in kWh
        Example: {0: 0.6, 1: 0.6, 2: 0.4, 3: 0.4, ...}
    """
    if not consumption_response:
        return {}

    nodes = consumption_response.get("nodes", [])
    if not nodes:
        return {}

    consumption_by_slot = {}
    for node in nodes:
        # Extract hour from "from" timestamp
        timestamp = node.get("from", "")
        if not timestamp:
            continue

        hour, _ = parse_time_from_timestamp(timestamp)
        consumption_value = node.get("consumption")

        if consumption_value != None:
            # Split hourly consumption into 2 slots (each gets half)
            half_hourly_value = float(consumption_value) / 2.0

            slot1 = hour * 2  # HH:00-HH:30
            slot2 = hour * 2 + 1  # HH:30-HH+1:00

            consumption_by_slot[slot1] = half_hourly_value
            consumption_by_slot[slot2] = half_hourly_value

    return consumption_by_slot

def get_color_for_level(level):
    """
    Map Tibber price level to color hex code.

    DEPRECATED: Use calculate_gradient_color() for smooth gradient coloring.
    This function is kept for backward compatibility and potential fallback scenarios.

    Args:
        level: Price level string (CHEAP, NORMAL, EXPENSIVE, VERY_EXPENSIVE)

    Returns:
        Hex color code string
    """
    colors = {
        "CHEAP": COLOR_CHEAP,
        "NORMAL": COLOR_NORMAL,
        "EXPENSIVE": COLOR_EXPENSIVE,
        "VERY_EXPENSIVE": COLOR_VERY_EXPENSIVE,
        "VERY_CHEAP": COLOR_CHEAP,  # Map VERY_CHEAP to same as CHEAP
    }
    return colors.get(level, COLOR_UNKNOWN)

def calculate_percentile(value, all_values):
    """
    Calculate percentile of a value within a list.

    Test cases:
    - calculate_percentile(3.5, [1.0, 2.0, 3.0, 4.0]) → 75
    - calculate_percentile(1.0, [1.0, 2.0, 3.0, 4.0]) → 25
    - calculate_percentile(4.0, [1.0, 2.0, 3.0, 4.0]) → 100
    - Edge case: All equal values → 50
    - Edge case: Empty list → 50

    Args:
        value: Value to find percentile for
        all_values: List of all values in dataset

    Returns:
        Integer percentile (0-100)
    """
    if not all_values or len(all_values) == 0:
        return 50

    # Check if all values are equal
    if len(set(all_values)) == 1:
        return 50

    # Sort values
    sorted_values = sorted(all_values)

    # Find position of value (or closest position)
    count_below = 0
    for v in sorted_values:
        if v < value:
            count_below += 1

    # Calculate percentile
    percentile = int((count_below / float(len(sorted_values))) * 100)

    return percentile

def calculate_efficiency_color(consumption_pct, price_pct, consumption_value = None):
    """
    Calculate efficiency color based on consumption and price percentiles.

    Special cases:
    - Negative or zero consumption (PV export) is always green (excellent)
    - Very low consumption (<= 1 kWh) with low percentile is green (PV systems)

    3×3 Matrix:
    - High cons (>75%) + High price (>75%) → Red #FF3B30 (inefficient)
    - High cons + Med price (25-75%) → Orange #FF9500
    - High cons + Low price (<25%) → Yellow #FFCC00 (acceptable)
    - Med cons (25-75%) + High price → Orange #FF9500
    - Med cons + Med price → Yellow #FFCC00 (neutral)
    - Med cons + Low price → Light Green #66E5A3
    - Low cons (<25%) + High price → Light Green #66E5A3 (excellent)
    - Low cons + Med price → Green #00D88A
    - Low cons + Low price → Green #00D88A (efficient)

    Test cases:
    - (80, 85, 5.0) → "#FF3B30" (high usage, high price)
    - (20, 20, 0.5) → "#00D88A" (low usage, low price)
    - (50, 50, 2.0) → "#FFCC00" (medium both)
    - (0, any, -1.0) → "#00D88A" (PV export is always excellent)
    - (100, 50, 0.8) → "#00D88A" (low absolute value with PV system)

    Args:
        consumption_pct: Consumption percentile (0-100)
        price_pct: Price percentile (0-100)
        consumption_value: Actual consumption in kWh (optional, for absolute checks)

    Returns:
        Hex color code string
    """

    # Special case 1: Negative or zero consumption (PV export) - always excellent
    if consumption_value != None and consumption_value <= 0:
        return "#00D88A"  # Green - PV export

    # Special case 2: Very low absolute consumption (<= 1 kWh) regardless of percentile
    # This handles PV systems where all values are low but one might be relatively higher
    if consumption_value != None and consumption_value <= 1.0:
        return "#00D88A"  # Green - minimal consumption (likely PV system)

    # Special case 3: Low percentile (bottom 5%) - always excellent
    if consumption_pct <= 5:
        return "#00D88A"  # Green - lowest consumption in dataset

    # Determine consumption level
    if consumption_pct > 75:
        cons_level = "high"
    elif consumption_pct >= 25:
        cons_level = "med"
    else:
        cons_level = "low"

    # Determine price level
    if price_pct > 75:
        price_level = "high"
    elif price_pct >= 25:
        price_level = "med"
    else:
        price_level = "low"

    # Apply matrix
    if cons_level == "high":
        if price_level == "high":
            return "#FF3B30"  # Red - inefficient
        elif price_level == "med":
            return "#FF9500"  # Orange
        else:
            return "#FFCC00"  # Yellow - acceptable
    elif cons_level == "med":
        if price_level == "high":
            return "#FF9500"  # Orange
        elif price_level == "med":
            return "#FFCC00"  # Yellow - neutral
        else:
            return "#66E5A3"  # Light green
    else:  # low consumption
        if price_level == "high":
            return "#66E5A3"  # Light green - excellent
        else:
            return "#00D88A"  # Green - efficient

def adjust_brightness(hex_color, factor):
    """
    Adjust the brightness of a hex color by a multiplicative factor.

    Used for highlighting the current hour by making colors brighter.
    Formula: new_value = min(255, old_value * factor)

    Args:
        hex_color: Hex color string (e.g., "#FF9500")
        factor: Brightness multiplier (e.g., 1.3 for 30% brighter)

    Returns:
        Adjusted hex color string with # prefix

    Examples:
        adjust_brightness("#FF9500", 1.3) → "#FFC200" (brighter orange)
        adjust_brightness("#00D88A", 1.3) → "#00FFB3" (brighter green)
    """
    if not hex_color or len(hex_color) != 7 or hex_color[0] != "#":
        return hex_color  # Return unchanged if invalid format

    # Extract RGB components
    r = int(hex_color[1:3], 16)
    g = int(hex_color[3:5], 16)
    b = int(hex_color[5:7], 16)

    # Apply factor and clamp to 255
    r = int(min(255, r * factor))
    g = int(min(255, g * factor))
    b = int(min(255, b * factor))

    # Format back to hex with proper padding
    def to_hex(val):
        hex_str = "%x" % val
        if len(hex_str) == 1:
            return "0" + hex_str
        return hex_str

    return "#" + to_hex(r).upper() + to_hex(g).upper() + to_hex(b).upper()

def interpolate_color(color1, color2, ratio):
    """
    Linearly interpolate between two hex colors.

    Used for gradient coloring to create smooth transitions between color stops.

    Args:
        color1: Start color (hex string like "#00D88A")
        color2: End color (hex string like "#FF3B30")
        ratio: Interpolation ratio (0.0 = color1, 1.0 = color2)

    Returns:
        Interpolated hex color string

    Examples:
        interpolate_color("#00D88A", "#FF3B30", 0.0) → "#00D88A"
        interpolate_color("#00D88A", "#FF3B30", 1.0) → "#FF3B30"
        interpolate_color("#000000", "#FFFFFF", 0.5) → "#7F7F7F" (gray)
    """
    if not color1 or not color2:
        return color1 or "#FFCC00"

    # Extract RGB from color1
    r1 = int(color1[1:3], 16)
    g1 = int(color1[3:5], 16)
    b1 = int(color1[5:7], 16)

    # Extract RGB from color2
    r2 = int(color2[1:3], 16)
    g2 = int(color2[3:5], 16)
    b2 = int(color2[5:7], 16)

    # Interpolate each component
    r = int(r1 + (r2 - r1) * ratio)
    g = int(g1 + (g2 - g1) * ratio)
    b = int(b1 + (b2 - b1) * ratio)

    # Format as hex
    def to_hex(val):
        hex_str = "%x" % val
        if len(hex_str) == 1:
            return "0" + hex_str
        return hex_str

    return "#" + to_hex(r).upper() + to_hex(g).upper() + to_hex(b).upper()

def create_gradient_bar(height, max_height, prev_height = None, next_height = None, use_grey = False):
    """
    Create a vertical gradient bar from green (bottom) to red (top), or grey gradient.

    Each bar displays a fixed vertical gradient regardless of price value.
    The height parameter determines how much of the gradient is visible:
    - Low prices (short bars): Only green portion visible
    - Medium prices: Green + yellow + orange visible
    - High prices (tall bars): Full gradient including red at top

    For sharp spikes, pixels that form the contour line (where a neighbor bar
    meets or exceeds the current height) remain bright to emphasize the shape.

    Gradient zones (from bottom to top):
    - Bottom 30%: Green (#00D88A) or Dark Grey (#404040)
    - 30-50%: Yellow-green to yellow transition or Grey gradient
    - 50-75%: Yellow to orange transition or Grey gradient
    - Top 25%: Orange to red (#FF3B30) or Light Grey (#808080)

    Args:
        height: Bar height in pixels (1 to max_height)
        max_height: Maximum possible bar height (typically 14px)
        prev_height: Height of previous bar (left neighbor) or None
        next_height: Height of next bar (right neighbor) or None
        use_grey: If True, use grey gradient instead of color gradient

    Returns:
        render.Stack widget with layered colored boxes creating gradient effect

    Examples:
        create_gradient_bar(3, 14) → short bar, only green visible
        create_gradient_bar(7, 14) → medium bar, green + yellow visible
        create_gradient_bar(14, 14) → tall bar, full gradient with red top
        create_gradient_bar(7, 14, use_grey=True) → grey gradient bar
    """
    if height <= 0:
        return render.Box(width = 1, height = 1, color = "#404040" if use_grey else "#00D88A")

    # Define gradient stops (colors at specific positions from bottom)
    # Each tuple is (position_ratio, color)
    if use_grey:
        gradient_stops = [
            (0.0, "#404040"),  # Bottom: Dark grey
            (0.3, "#505050"),  # Darker grey
            (0.5, "#606060"),  # Medium grey
            (0.65, "#707070"),  # Medium-light grey
            (0.8, "#787878"),  # Light grey
            (0.9, "#7C7C7C"),  # Lighter grey
            (1.0, "#808080"),  # Top: Light grey
        ]
    else:
        gradient_stops = [
            (0.0, "#00D88A"),  # Bottom: Green
            (0.3, "#33E5A0"),  # Light green
            (0.5, "#FFCC00"),  # Yellow
            (0.65, "#FFB733"),  # Orange-yellow
            (0.8, "#FF9500"),  # Orange
            (0.9, "#FF6B33"),  # Red-orange
            (1.0, "#FF3B30"),  # Top: Red
        ]

    # Build vertical gradient by stacking colored pixels
    pixels = []
    for pixel_index in range(height):
        # Calculate position in gradient (0.0 = top/red, 1.0 = bottom/green)
        # pixel_index 0 is top of bar, should be red
        # pixel_index height-1 is bottom of bar, should be green
        position_from_bottom = (height - 1 - pixel_index) / float(max_height)

        # Find which gradient segment this pixel falls into
        color = "#00D88A"  # Default green
        for i in range(len(gradient_stops) - 1):
            pos1, color1 = gradient_stops[i]
            pos2, color2 = gradient_stops[i + 1]

            if position_from_bottom >= pos1 and position_from_bottom <= pos2:
                # Interpolate between these two stops
                ratio = (position_from_bottom - pos1) / (pos2 - pos1)
                color = interpolate_color(color1, color2, ratio)
                break

        # Determine if this pixel should be bright (contour pixel)
        # A pixel is part of the contour if:
        # 1. It's the topmost pixel (pixel_index 0), OR
        # 2. This pixel is at the edge where a neighbor's height ends
        #    (neighbor is shorter and this pixel is at or just above neighbor's top)
        is_contour = False
        if pixel_index == 0:
            is_contour = True
        else:
            # Check if this pixel is at the contour line
            # A pixel at height H from bottom is contour if a neighbor has height < H
            # meaning this pixel is exposed/visible from the side
            pixel_height_from_bottom = height - pixel_index

            # Check left neighbor - if it's shorter, we're on the contour
            if prev_height != None and prev_height < pixel_height_from_bottom:
                is_contour = True

            # Check right neighbor - if it's shorter, we're on the contour
            if next_height != None and next_height < pixel_height_from_bottom:
                is_contour = True

        # Apply brightness reduction if not a contour pixel
        # Interior pixels get darker from top to bottom for depth effect
        if not is_contour:
            # Calculate brightness based on position: darker at bottom, brighter at top
            # pixel_index 0 = top (would be contour anyway)
            # pixel_index height-1 = bottom (darkest interior pixel)
            # Use ratio from 0.05 (very dark at bottom) to 0.3 (dimmer at top, but still distinct from contour)
            position_ratio = float(pixel_index) / float(height - 1) if height > 1 else 0
            brightness_factor = 0.3 - (position_ratio * 0.25)  # 0.3 at top interior → 0.05 at bottom
            color = adjust_brightness(color, brightness_factor)

        # Create 1px high colored box
        pixels.append(render.Box(
            width = 1,
            height = 1,
            color = color,
        ))

    # Stack pixels vertically
    return render.Column(
        main_align = "start",
        cross_align = "start",
        children = pixels,
    )

def calculate_bar_height(price, all_prices, max_height):
    """
    Calculate proportional bar height for a price.

    Uses proportional scaling with minimum height of 2px.
    Formula: (price - min) / (max - min) * (max_height - 2) + 2

    Args:
        price: Target price value
        all_prices: List of all price values for scaling
        max_height: Maximum bar height in pixels

    Returns:
        Bar height in pixels (2 to max_height)
    """
    if not all_prices or len(all_prices) == 0:
        return 2

    min_price = min(all_prices)
    max_price = max(all_prices)

    # If all prices are the same, return middle height
    if max_price == min_price:
        return int(max_height / 2)

    # Proportional scaling: map price range to height range (2 to max_height)
    ratio = (price - min_price) / (max_price - min_price)
    height = ratio * (max_height - 2) + 2

    return int(height)

def select_24h_forecast(prices, current_slot, consumption_data = None):
    """
    Select 60 half-hourly slots starting from 00:00 today for forward-looking forecast.

    Shows slots 0-59 (today 00:00 through tomorrow 05:30), filling the full 60px
    display width. Always anchored to start of day regardless of current time.

    Args:
        prices: List of price dicts with 'slot' key (0-95 for today+tomorrow)
        current_slot: Current slot (0-47) for marking is_current_slot
        consumption_data: Dict mapping slot → kWh (optional, from API)

    Returns:
        List of 60 price dicts (slots 0-59) with:
        - is_current_slot: Boolean flag for current slot
        - consumption_kwh: Float (kWh) or None
        - efficiency_color: Hex color based on consumption vs price percentiles
    """

    # Select slots 0-59 (starting from 00:00 today)
    forecast_slots = []
    for target_slot in range(60):
        # Find price for this slot
        price_entry = None
        for price in prices:
            if price["slot"] == target_slot:
                price_entry = price
                break

        if price_entry:
            # Mark current slot
            price_entry["is_current_slot"] = (target_slot == current_slot)
            price_entry["is_placeholder"] = False

            # Add consumption data if available (only for today's slots)
            if consumption_data and target_slot < 48 and target_slot in consumption_data:
                price_entry["consumption_kwh"] = consumption_data[target_slot]
            else:
                price_entry["consumption_kwh"] = None

            forecast_slots.append(price_entry)
        else:
            # No data for this slot - create placeholder at last known price level
            # This ensures we always have 60 slots even if tomorrow's prices aren't available
            # Use the last known price (slot 47) if available, otherwise average
            last_known_price = 0.5
            if len(forecast_slots) > 0:
                # Use the last slot's price
                last_known_price = forecast_slots[-1]["price"]
            else:
                # Fallback to average of available prices
                total_price = 0.0
                for p in prices:
                    total_price = total_price + p["price"]
                last_known_price = total_price / len(prices) if len(prices) > 0 else 0.5

            forecast_slots.append({
                "price": last_known_price,
                "level": "NORMAL",
                "slot": target_slot,
                "hour": target_slot // 2,
                "minute": 30 if target_slot % 2 else 0,
                "is_current_slot": False,
                "is_placeholder": True,
                "consumption_kwh": None,
            })

    # Calculate efficiency colors if we have consumption data
    if consumption_data and len(consumption_data) > 0:
        # Extract all consumption and price values for percentile calculation
        all_consumptions = []
        all_prices = []
        for p in forecast_slots:
            if p["consumption_kwh"] != None:
                all_consumptions.append(p["consumption_kwh"])
            all_prices.append(p["price"])

        # Calculate efficiency color for each slot
        for price in forecast_slots:
            if price["consumption_kwh"] != None:
                cons_pct = calculate_percentile(price["consumption_kwh"], all_consumptions)
                price_pct = calculate_percentile(price["price"], all_prices)
                price["efficiency_color"] = calculate_efficiency_color(
                    cons_pct,
                    price_pct,
                    price["consumption_kwh"],
                )
            else:
                price["efficiency_color"] = None
    else:
        # No consumption data - set all to None (gray placeholder)
        for price in forecast_slots:
            price["efficiency_color"] = None

    return forecast_slots

def format_current_price(price):
    """
    Format price for display.

    Args:
        price: Price as float

    Returns:
        Formatted string like "0.25 kr"
    """

    # Round to 2 decimals and format manually (Starlark doesn't support .2f)
    rounded = int(price * 100 + 0.5) / 100.0

    # Convert to string with 2 decimal places
    price_str = str(rounded)

    # Ensure we have 2 decimal places
    if "." not in price_str:
        price_str = price_str + ".00"
    else:
        parts = price_str.split(".")
        if len(parts[1]) == 1:
            price_str = price_str + "0"
        elif len(parts[1]) > 2:
            price_str = parts[0] + "." + parts[1][:2]

    return price_str + " kr"

def format_hour_label(hour):
    """
    Format hour for display.

    Args:
        hour: Hour as integer (0-23)

    Returns:
        Hour string without leading zero
    """
    return str(hour)

def render_current_price(price_point):
    """
    Render current price widget.

    Args:
        price_point: Dict with keys: price, level, hour

    Returns:
        render widget for current price display
    """
    color = get_color_for_level(price_point["level"])
    price_text = format_current_price(price_point["price"])

    return render.Column(
        main_align = "center",
        cross_align = "start",
        children = [
            render.Text("NOW", font = "tom-thumb"),
            render.Text(price_text, color = color),
        ],
    )

def render_bar_chart(forecast, max_height):
    """
    Render bar chart for price forecast with 60 half-hourly bars.

    Shows next 30 hours (60 × 30-minute slots) starting from current time,
    filling the full 60px width.

    Args:
        forecast: List of price dicts (up to 60 slots)
        max_height: Maximum bar height in pixels

    Returns:
        render widget with bar chart
    """
    if not forecast or len(forecast) == 0:
        return render.Box(width = 1, height = max_height)

    # Extract prices for scaling
    prices = [p["price"] for p in forecast]

    # Pre-calculate all bar heights for neighbor access
    heights = []
    for price_point in forecast:
        if len(heights) >= 60:
            break
        height = calculate_bar_height(price_point["price"], prices, max_height)
        heights.append(height)

    # Create bars split into two groups (30+30) to avoid Row's 24-child limit
    bars_left = []
    bars_right = []

    for i in range(len(heights)):
        if i >= 60:
            break

        height = heights[i]
        prev_height = heights[i - 1] if i > 0 else None
        next_height = heights[i + 1] if i < len(heights) - 1 else None

        # Check if this slot is a placeholder (unknown price)
        is_placeholder = forecast[i].get("is_placeholder", False)

        bar = create_gradient_bar(height, max_height, prev_height, next_height, use_grey = is_placeholder)

        if i < 30:
            bars_left.append(bar)
        else:
            bars_right.append(bar)

    # Create two Rows side by side (no spacer needed - 60px exactly)
    return render.Row(
        main_align = "start",
        cross_align = "end",
        children = [
            render.Row(
                main_align = "start",
                cross_align = "end",
                children = bars_left,
            ),
            render.Row(
                main_align = "start",
                cross_align = "end",
                children = bars_right,
            ),
        ],
    )

def render_hour_labels(forecast):
    """
    Render hour labels below bar chart.

    Shows labels for every 3rd hour to avoid crowding.

    Args:
        forecast: List of price dicts

    Returns:
        render widget with hour labels
    """
    if not forecast or len(forecast) == 0:
        return render.Box(width = 1, height = 1)

    labels = []
    for i, price_point in enumerate(forecast):
        if i >= 12:  # Limit to 12
            break

        # Show label every 3 hours
        if i % 3 == 0:
            label_text = format_hour_label(price_point["hour"])
            label = render.Text(label_text, font = "tom-thumb")

            # Calculate position (4px bar + 1px spacing)
            offset = i * 5
            labels.append(render.Padding(
                pad = (offset, 0, 0, 0),
                child = label,
            ))

    return render.Stack(children = labels)

def create_consumption_gradient_bar(height, base_color, prev_height = None, next_height = None):
    """
    Create a consumption bar with contour highlighting and depth gradient.

    Similar to price gradient bars but uses a single base color (efficiency color)
    with brightness variations for contour and depth effects.

    Args:
        height: Bar height in pixels
        base_color: Base efficiency color for this bar
        prev_height: Height of previous bar (left neighbor) or None
        next_height: Height of next bar (right neighbor) or None

    Returns:
        render.Column widget with contour highlighting and depth gradient
    """
    if height <= 0:
        return render.Box(width = 1, height = 1, color = base_color)

    # Build vertical bar by stacking colored pixels
    pixels = []
    for pixel_index in range(height):
        # Start with base color
        color = base_color

        # Determine if this pixel should be bright (contour pixel)
        is_contour = False
        if pixel_index == 0:
            is_contour = True
        else:
            # Check if this pixel is at the contour line
            pixel_height_from_bottom = height - pixel_index

            # Check left neighbor - if it's shorter, we're on the contour
            if prev_height != None and prev_height < pixel_height_from_bottom:
                is_contour = True

            # Check right neighbor - if it's shorter, we're on the contour
            if next_height != None and next_height < pixel_height_from_bottom:
                is_contour = True

        # Apply brightness reduction if not a contour pixel
        # Interior pixels get darker from top to bottom for depth effect
        if not is_contour:
            # Calculate brightness based on position: darker at bottom, brighter at top
            position_ratio = float(pixel_index) / float(height - 1) if height > 1 else 0
            brightness_factor = 0.3 - (position_ratio * 0.25)  # 0.3 at top interior → 0.05 at bottom
            color = adjust_brightness(color, brightness_factor)

        # Create 1px high colored box
        pixels.append(render.Box(
            width = 1,
            height = 1,
            color = color,
        ))

    # Stack pixels vertically
    return render.Column(
        main_align = "start",
        cross_align = "start",
        children = pixels,
    )

def render_consumption_chart(forecast, max_height, current_slot):
    """
    Render consumption chart with 60 bars matching price chart width.

    Shows consumption where available (past slots only) and future slots as
    dark gray placeholders. Accepts that consumption will never be complete
    for forward-looking forecast.

    Args:
        forecast: List of price dicts with consumption_kwh and efficiency_color
        max_height: Maximum bar height in pixels
        current_slot: Current slot (0-47) to determine past vs future

    Returns:
        render widget with consumption chart
    """
    if not forecast or len(forecast) == 0:
        return render.Box(width = 1, height = max_height)

    # Extract consumption values for scaling (only from past slots)
    consumptions = []
    for p in forecast:
        if p.get("consumption_kwh") != None:
            consumptions.append(p["consumption_kwh"])

    # Pre-calculate all bar heights for neighbor access
    heights = []
    for i, price_point in enumerate(forecast):
        if i >= 60:
            break

        slot = price_point.get("slot", 9999)

        # Only show consumption for past slots (< current_slot)
        if slot < current_slot:
            consumption_kwh = price_point.get("consumption_kwh")
            if consumption_kwh != None and len(consumptions) > 0:
                min_cons = min(consumptions)
                max_cons = max(consumptions)
                if max_cons > min_cons:
                    ratio = (consumption_kwh - min_cons) / (max_cons - min_cons)
                    height = int(ratio * (max_height - 1) + 1)
                    if height < 1:
                        height = 1
                else:
                    height = int(max_height / 2)
            else:
                height = 1
        else:
            # Future slot - show minimal gray bar
            height = 1

        heights.append(height)

    # Create bars split into two groups (30+30)
    bars_left = []
    bars_right = []

    for i in range(len(heights)):
        if i >= 60:
            break

        price_point = forecast[i]
        slot = price_point.get("slot", 9999)
        height = heights[i]
        prev_height = heights[i - 1] if i > 0 else None
        next_height = heights[i + 1] if i < len(heights) - 1 else None

        # Only show consumption for past slots (< current_slot)
        if slot < current_slot:
            color = price_point.get("efficiency_color") or "#808080"
            bar = create_consumption_gradient_bar(height, color, prev_height, next_height)
        else:
            # Future slot - show minimal gray bar (no gradient)
            bar = render.Box(
                width = 1,
                height = height,
                color = "#404040",
            )

        if i < 30:
            bars_left.append(bar)
        else:
            bars_right.append(bar)

    return render.Row(
        main_align = "start",
        cross_align = "end",
        children = [
            render.Row(
                main_align = "start",
                cross_align = "end",
                children = bars_left,
            ),
            render.Row(
                main_align = "start",
                cross_align = "end",
                children = bars_right,
            ),
        ],
    )

def render_main_display(forecast_data, current_slot, cache_status, is_demo = False):
    """
    Compose main display with two horizontal charts.

    Args:
        forecast_data: Dict with keys: prices, currency, consumption (optional)
        current_slot: Current slot (0-47) for 30-minute granularity
        cache_status: Cache status string
        is_demo: Boolean flag indicating demo mode

    Returns:
        render.Root widget
    """

    # Extract consumption data if available
    consumption_data = forecast_data.get("consumption", {})

    # Select 48-slot forecast for current day with consumption and efficiency colors
    forecast = select_24h_forecast(
        forecast_data["prices"],
        current_slot,
        consumption_data,
    )

    if not forecast or len(forecast) == 0:
        return render_error("no_data")

    # Render dual horizontal charts - full width, no sidebar or legend
    price_chart = render_bar_chart(forecast, max_height = 14)
    consumption_chart = render_consumption_chart(forecast, max_height = 14, current_slot = current_slot)

    # Add stale indicator if needed
    stale_indicator = None
    if cache_status == "stale":
        stale_indicator = render.Padding(
            pad = (0, 0, 2, 2),
            child = render.Text("*", font = "tom-thumb", color = "#FF9500"),
        )

    # Compose dual horizontal layout
    layout_children = [
        render.Padding(
            pad = (2, 2, 2, 0),
            child = price_chart,
        ),
        render.Padding(
            pad = (2, 2, 2, 2),
            child = consumption_chart,
        ),
    ]

    if stale_indicator:
        layout_children.append(stale_indicator)

    # Create base display
    base_display = render.Column(
        main_align = "start",
        cross_align = "start",
        children = layout_children,
    )

    # Add demo overlay if in demo mode
    if is_demo:
        return render.Root(
            child = render.Stack(
                children = [
                    base_display,
                    render.Box(
                        width = 64,
                        height = 32,
                        child = render.Column(
                            main_align = "center",
                            cross_align = "center",
                            children = [
                                render.Text(
                                    "DEMO",
                                    font = "6x13",
                                    color = "#FFFFFF",
                                ),
                            ],
                        ),
                    ),
                ],
            ),
        )

    return render.Root(child = base_display)

def main(config):
    """
    Main entry point for the Tidbyt app.

    Args:
        config: Configuration dict with api_token

    Returns:
        render.Root widget
    """

    # Validate configuration
    api_token = config.get("api_token")
    if not api_token:
        # Use demo token if no token provided
        api_token = TIBBER_DEMO_TOKEN
        is_demo = True
    else:
        is_demo = (api_token == TIBBER_DEMO_TOKEN)

    # Get cached or fresh data
    result = get_cached_prices(api_token)

    # Handle errors
    if not result["success"]:
        return render_error(result["error_code"])

    # Parse data
    forecast_data = parse_tibber_response(result["data"])

    # Get current 30-minute slot using device's configured timezone
    # The device's timezone is automatically provided by Tidbyt in config
    # Slot calculation: hour * 2 + (1 if minute >= 30 else 0)
    timezone = config.get("timezone") or config.get("$tz") or "UTC"
    current_slot = calculate_current_slot(timezone)

    # Render main display
    return render_main_display(
        forecast_data,
        current_slot,
        result["cache_status"],
        is_demo,
    )

def render_error(error_code):
    """
    Render error message for user.

    Args:
        error_code: Error type (missing_token, unauthorized, rate_limited, etc.)

    Returns:
        render.Root widget with error message
    """
    error_messages = {
        "missing_token": "Configure API Token",
        "unauthorized": "Invalid Token",
        "rate_limited": "Rate Limited - Wait 10s",
        "timeout": "Network Error",
        "server_error": "Tibber API Error",
        "no_data": "No Price Data",
        "unknown": "HTTP Error",
        "graphql_error": "GraphQL Error",
        "parse_error": "Data Parse Error",
        "no_homes": "No Tibber Home Found",
    }

    message = error_messages.get(error_code, "Unknown Error")

    return render.Root(
        child = render.Box(
            child = render.Column(
                main_align = "center",
                cross_align = "center",
                children = [
                    render.Text("Error", color = "#FF0000"),
                    render.Text(message, font = "tom-thumb"),
                ],
            ),
        ),
    )

def get_schema():
    """
    Define configuration schema for the app.

    Returns:
        schema.Schema with required fields
    """
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "api_token",
                name = "Tibber API Token",
                desc = "Your Tibber API token from developer.tibber.com. Leave empty for demo mode.",
                icon = "key",
                default = TIBBER_DEMO_TOKEN,
            ),
        ],
    )
