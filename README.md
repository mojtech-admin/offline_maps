# OffRoute

An iPhone driving map that works with **no internet and no GPS**. It follows the car using the
phone's motion sensors and rear camera, on road maps stored on the phone.

First maps: Arizona, California, Colorado, Massachusetts (from OpenStreetMap).

## What it does

- Moving road map, drawn from on-device data, heading-up while driving
- Position by dead reckoning: gyroscope for turns, camera optical flow for speed, map matching
  to keep the car on roads and to re-fix its position at every corner
- Turn-by-turn routing with spoken directions, automatic rerouting
- Offline search for cities, streets, addresses and places
- Speed limit from map data and from reading "SPEED LIMIT" signs; warning when exceeded
- Camera view with the route painted on the road ahead
- Street-name signs used as extra position evidence

## How position works without GPS

1. You tell the app where you are once (drag the map under the cross and tap **I am here**).
2. Speed comes from how fast the road surface moves through the camera picture, fused with the
   accelerometer and stand-still detection.
3. A particle filter moves 80 position guesses along the road network. A guess may not go round a
   corner until the gyroscope feels the turn, and a guess whose road no longer matches the car's
   heading jumps to the nearest road that does. Each turn therefore pins the position down again
   and teaches the app how far off its speed scale is.

Limits you should know about:

- On a long straight road with no bends the error grows with distance (a few percent once the
  speed scale has been learned, more on the first drive).
- If the camera cannot see the road (night, heavy rain, covered lens) speed is only a guess and
  position quality drops sharply.
- Routes do not cross state lines yet. Turn restrictions are not modelled.
- The app must stay on screen; sensors and camera stop in the background.
- Landscape only, phone in a mount with the rear camera facing the road.

The filter has been tested in simulation only (`tools/coretest`), not yet on a real drive.

## Repository layout

| Path | What |
| --- | --- |
| `App/Core` | Pure Swift navigation core: pack reader, router, dead reckoner, sign parser |
| `App/Services` | Sensors, camera, search, downloads, voice, the engine tying it together |
| `App/UI` | SwiftUI screens |
| `tools/build_pack.py` | Turns an OpenStreetMap extract into a state map pack |
| `tools/check_pack.py` | Verifies a pack and prints a sample route |
| `tools/coretest` | Command-line simulation of the navigation core |
| `.github/workflows/maps.yml` | Builds the four state packs and publishes them as release `maps-v1` |
| `.github/workflows/ios.yml` | Compiles the app; optionally signs it and uploads to TestFlight |
| `project.yml` | XcodeGen description of the Xcode project |
| `docs/PACK_FORMAT.md` | Binary layout of the `.roads` file |

## Building without a Mac

Everything runs on GitHub Actions. See the publishing guide for the full walkthrough. In short:

1. Run the **Build map packs** workflow once.
2. Every push compiles the app. Run **Build iPhone app** with *upload* ticked to send a signed
   build to TestFlight (needs the Apple secrets described in the guide).

Repository settings used by the build:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `BUNDLE_ID` | e.g. `com.yourname.offroute` |
| Secret | `APPLE_TEAM_ID` | 10-character Apple team ID |
| Secret | `ASC_KEY_ID` | App Store Connect API key ID |
| Secret | `ASC_ISSUER_ID` | App Store Connect issuer ID |
| Secret | `ASC_KEY_P8` | Full text of the downloaded `AuthKey_XXXX.p8` file |

## Adding a state

Add a line to the matrix in `.github/workflows/maps.yml` (Geofabrik region name) and an entry to
`StateInfo.all` in `App/Services/PackStore.swift`, then re-run the maps workflow.

## Credits

Map data © OpenStreetMap contributors, Open Database License (ODbL) 1.0.
