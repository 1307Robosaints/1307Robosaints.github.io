"""Supabase access through its REST API, using the service role key.

The service role key skips row-level security, which is what lets this worker write
vision_matches / vision_robots. Keep it in vision/.env on this laptop only: never commit it
and never put it in the website.
"""
import requests

PAGE = 1000


class Db:
    def __init__(self, url, key):
        self.base = url.rstrip("/") + "/rest/v1/"
        self.http = requests.Session()
        self.http.headers.update({"apikey": key, "Authorization": "Bearer " + key,
                                  "Content-Type": "application/json"})

    def select(self, table, **params):
        """Every row matching PostgREST filters, e.g. select("events", tba_event_key="eq.2026nhgrs")."""
        rows, offset = [], 0
        while True:
            r = self.http.get(self.base + table, params={**params, "limit": PAGE, "offset": offset}, timeout=30)
            if not r.ok:
                raise RuntimeError(f"{table}: HTTP {r.status_code} {r.text[:300]}")
            batch = r.json()
            rows += batch
            if len(batch) < PAGE:
                return rows
            offset += PAGE

    def upsert(self, table, rows, on_conflict):
        if not rows:
            return
        r = self.http.post(self.base + table, params={"on_conflict": on_conflict}, json=rows, timeout=30,
                           headers={"Prefer": "resolution=merge-duplicates,return=minimal"})
        if not r.ok:
            raise RuntimeError(f"{table}: HTTP {r.status_code} {r.text[:300]}")

    def delete(self, table, **filters):
        r = self.http.delete(self.base + table, params=filters, timeout=30)
        if not r.ok:
            raise RuntimeError(f"{table}: HTTP {r.status_code} {r.text[:300]}")

    # ── Lookups the pipeline needs ──────────────────────────────────
    def event(self, tba_key):
        rows = self.select("events", tba_event_key=f"eq.{tba_key}", select="id,name,event_date,tba_event_key")
        if not rows:
            raise SystemExit(f"No event has TBA key {tba_key}. Link it in the Staff Portal first.")
        return rows[0]

    def official_matches(self, event_id):
        """Played or scheduled matches for an event, by match_key, from the combined FRC/TBA view."""
        rows = self.select("official_matches_combined", event_id=f"eq.{event_id}",
                           select="match_key,comp_level,red_teams,blue_teams,red_score,blue_score,red_breakdown,blue_breakdown")
        return {r["match_key"]: r for r in rows}

    def save_match(self, event_id, match_row, robot_rows):
        """Replaces this match's vision rows, so a robot dropped on a re-run doesn't linger."""
        key = match_row["match_key"]
        self.upsert("vision_matches", [{"event_id": event_id, **match_row}], "event_id,match_key")
        self.delete("vision_robots", event_id=f"eq.{event_id}", match_key=f"eq.{key}")
        self.upsert("vision_robots", [{"event_id": event_id, "match_key": key, **r} for r in robot_rows],
                    "event_id,match_key,team_number")
