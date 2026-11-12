// Paste values from Supabase > Project Settings > API.
// The anon key is MEANT to be public; the database rules (SQL/rebuild_all.sql) protect the data.
window.AUTH_CONFIG = {
  url: "https://nyanwljgsazwuzmnlrcz.supabase.co",
  anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im55YW53bGpnc2F6d3V6bW5scmN6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMwNjkyMjcsImV4cCI6MjEwODY0NTIyN30.3Js9WsLo3i4fPQl1WiXQCGcT94PJPamXapBXeV-Hpoo",
  memberDomain: "stalux.org",
  // Match alerts (js/alerts.js): the PUBLIC VAPID key from `npx web-push generate-vapid-keys`.
  // Blank turns the My Account switch off. The private key is a match-alerts function secret.
  pushKey: "BEsCv2p5AeBZSWTleWuJGwpJS0aIDKgkWRJFrv0pb_iM_S5nPdOokMZEUMT1VwWr7v8UBvM-4aB2npXtt8nLFGY"
};
