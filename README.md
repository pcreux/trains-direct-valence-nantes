# Direct trains — Valence TGV ↔ Angers · Nantes

Lists all direct TGV connections between Valence TGV and Angers / Nantes for the next month.

**[→ View the schedule](https://pcreux.github.io/trains-direct-valence-nantes/)**

## How it works

`generate.rb` queries the [SNCF API](https://api.sncf.com) (powered by [Navitia](https://navitia.io)) for direct journeys (no transfers) on each of the four routes, then renders a static `index.html`.

A GitHub Actions workflow runs every day at 6 AM Paris time to keep the schedule up to date.

## Run locally

```bash
NAVITIA_TOKEN=your_token ruby generate.rb
```
