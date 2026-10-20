"""
Converts Prasarana's rapid-bus-penang GTFS feed into assets/bus_stops.json
for the Routepool HUB screen.

Usage:
    pip install requests
    python gtfs_to_json.py

Fetches the feed fresh from Malaysia's official open data API
(https://developer.data.gov.my), no API key required, then writes
assets/bus_stops.json in the format hub_screen.dart's BusStop.fromJson
expects: stop_id, stop_name, stop_lat, stop_lon.

Re-run this periodically (e.g. monthly) since Prasarana updates the feed
"as required" rather than on a fixed schedule.
"""

import csv
import io
import json
import zipfile

import requests

GTFS_URL = "https://api.data.gov.my/gtfs-static/prasarana?category=rapid-bus-penang"
OUTPUT_PATH = "assets/bus_stops.json"


def main() -> None:
    print(f"Downloading GTFS feed from {GTFS_URL} ...")
    response = requests.get(GTFS_URL, timeout=60)
    response.raise_for_status()

    with zipfile.ZipFile(io.BytesIO(response.content)) as feed:
        with feed.open("stops.txt") as stops_file:
            reader = csv.DictReader(io.TextIOWrapper(stops_file, encoding="utf-8-sig"))
            stops = [
                {
                    "stop_id": row["stop_id"],
                    "stop_name": row["stop_name"],
                    "stop_lat": float(row["stop_lat"]),
                    "stop_lon": float(row["stop_lon"]),
                }
                for row in reader
                if row.get("stop_lat") and row.get("stop_lon")
            ]

    with open(OUTPUT_PATH, "w", encoding="utf-8") as out:
        json.dump(stops, out, ensure_ascii=False, indent=2)

    print(f"Wrote {len(stops)} stops to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()