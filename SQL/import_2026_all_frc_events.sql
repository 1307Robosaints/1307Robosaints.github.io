-- =====================================================================
-- 1307scout: DATA IMPORT ONLY — every official 2026 FRC event
--
-- Row-only changes to public.events. No schema, policy or function
-- changes, but it sets event_tier, so run rebuild_all.sql first. Safe to
-- re-run: a second run adds nothing.
--
-- What it adds: all 213 played 2026 on-season events, worldwide —
-- regionals, district events, district championships (and their
-- divisions and finals), the 8 FIRST Championship divisions and Einstein.
-- Off-season and pre-season ("Week 0") events are not included: FIRST
-- doesn't run them, their FRC and TBA codes often don't match, and the
-- New England ones are already in import_ne_offseason_2026.sql.
-- ISDE3 and ISDE4 are left out because they were never played (see
-- import_israel_events.sql).
--
-- Source: The Blue Alliance 2026 event list (keys, names, venues, dates,
-- event types), cross-checked against frc-events.firstinspires.org/2026/
-- events/EventList for the FRC codes, read 2026-11-07. Every TBA key's
-- FRC code is the same code in capitals, except the Worlds divisions
-- (TBA 2026arc = FRC ARCHIMEDES, and so on).
--
-- How overlap is avoided:
--   - Section 1 fixes the TBA keys on the Worlds division rows from
--     import_championships.sql. They were saved as e.g. 2026archimedes,
--     but TBA's key is 2026arc, so TBA sync for those rows never worked.
--   - An event is skipped if any row already has its TBA key, or has its
--     FRC code in the same season. Matching on the code alone isn't
--     enough: FIRST reuses codes every year (MABIL '26 vs MABIL '27).
--   - A row staff added by hand with the same name and no codes is
--     linked to its codes instead of getting a duplicate (section 3).
--   Events from the earlier imports (NE district events, NE champs,
--   Worlds, Israel) are already in the table, so they're skipped. Their
--   values below match what those imports used, so a fresh database gets
--   the same rows either way.
--
-- Names follow this project's convention, "<Short name> '26", using
-- TBA's short name. District championship finals (the single-day event
-- between division winners) are named "<District> Finals '26", like
-- Einstein for Worlds.
--
-- event_date follows this project's usual rule: the day before the
-- event's last day. Israel uses its makeup dates, as in
-- import_israel_events.sql.
--
-- This adds the events only. Match results arrive when official-sync
-- runs (Resync All in the Staff Portal, one event at a time, so 200+
-- events takes a while). Note that prune_non_ne_teams.sql removes every
-- event outside New England, so re-running it would undo this import.
--
-- HOW TO RUN: paste the whole file into the SQL Editor and run it. It
-- runs as one transaction, so any error leaves the database unchanged.
-- =====================================================================


-- =====================================================================
-- 1. Correct TBA keys on the existing 2026 Worlds division rows. Only
--    changes the exact wrong value, so it's a no-op after.
-- =====================================================================
update public.events e
set tba_event_key = left(e.tba_event_key, 4) || v.tba_code
from (values
  ('archimedes', 'arc'), ('curie', 'cur'), ('daly', 'dal'), ('galileo', 'gal'),
  ('hopper', 'hop'), ('johnson', 'joh'), ('milstein', 'mil'), ('newton', 'new')
) as v(old_code, tba_code)
where e.tba_event_key = '2026' || v.old_code;


-- =====================================================================
-- 2. The 2026 event list
-- =====================================================================
create temp table import_2026 on commit drop as
select v.name, v.location, v.event_date::date as event_date,
       v.frc_event_code, v.tba_event_key, v.event_tier
from (values
  ('İstanbul ''26', 'Başakşehir / İstanbul, Türkiye', '2026-03-04', 'TUIS', '2026tuis', 'qualifier'),
  ('Canadian Pacific ''26', 'Pacific Coliseum, Vancouver, BC, Canada', '2026-03-06', 'BCVI', '2026bcvi', 'qualifier'),
  ('Lake Superior ''26', 'DECC Arena/South Pioneer Hall, Duluth, MN', '2026-03-06', 'MNDU', '2026mndu', 'qualifier'),
  ('Northern Lights ''26', 'DECC Arena/Edmund Fitzgerald Exhibit Hall, Duluth, MN', '2026-03-06', 'MNDU2', '2026mndu2', 'qualifier'),
  ('Minnesota Bluff Country ''26', 'St. Mary''s University, Winona, MN', '2026-03-06', 'MNWI', '2026mnwi', 'qualifier'),
  ('Oklahoma ''26', 'Chisholm Trail Expo Center, Enid, OK', '2026-03-06', 'OKOK', '2026okok', 'qualifier'),
  ('Festival SESI de Educação ''26', 'Fundação Bienal de São Paulo, São Paulo, Brazil', '2026-03-07', 'BRBA', '2026brba', 'qualifier'),
  ('Pikes Peak ''26', 'Coronado High School, Colorado Springs, CO', '2026-03-07', 'COSP', '2026cosp', 'qualifier'),
  ('Dalton ''26', 'Dalton Convention Center, Dalton, GA', '2026-03-06', 'GADAL', '2026gadal', 'qualifier'),
  ('Lakeview ''26', 'Lakeview High School, Battle Creek, MI', '2026-03-06', 'MILAK', '2026milak', 'qualifier'),
  ('Oregon State Fair ''26', 'Oregon State Fairgrounds, Salem, OR', '2026-03-06', 'ORSAL', '2026orsal', 'qualifier'),
  ('North Charleston ''26', 'The City of North Charleston Athletic Center, North Charleston, SC', '2026-03-06', 'SCCHA', '2026sccha', 'qualifier'),
  ('Belton ''26', 'Cadance Bank Center, Belton, TX', '2026-03-06', 'TXBEL', '2026txbel', 'qualifier'),
  ('Half Moon Bay ''26', 'Boys & Girls Club of the Coastside, Half Moon Bay, CA', '2026-03-07', 'CAHAL', '2026cahal', 'qualifier'),
  ('Hueneme Port ''26', 'Port of Hueneme, Port Hueneme, CA', '2026-03-07', 'CAPOH', '2026capoh', 'qualifier'),
  ('Mishawaka ''26', 'Penn High School, Mishawaka, IN', '2026-03-07', 'INMIS', '2026inmis', 'qualifier'),
  ('Minuteman ''26', 'Billerica Memorial High School, Billerica, MA', '2026-03-07', 'MABIL', '2026mabil', 'qualifier'),
  ('Pine Tree ''26', 'Falmouth High School, Falmouth, ME', '2026-03-07', 'MEFAL', '2026mefal', 'qualifier'),
  ('Chelsea ''26', 'Chelsea High School, Chelsea, MI', '2026-03-07', 'MICHE', '2026miche', 'qualifier'),
  ('Mt Pleasant ''26', 'Mt Pleasant High School, Mt Pleasant, MI', '2026-03-07', 'MIMTP', '2026mimtp', 'qualifier'),
  ('Cabarrus ''26', 'Cox Mill High School, Concord, NC', '2026-03-07', 'NCCAB', '2026nccab', 'qualifier'),
  ('Wake County #1 ''26', 'Heritage High School, Wake Forest, NC', '2026-03-07', 'NCWAK', '2026ncwak', 'qualifier'),
  ('Warren Hills ''26', 'Warren Hills High School, Washington, NJ', '2026-03-07', 'NJWAS', '2026njwas', 'qualifier'),
  ('Hatboro-Horsham ''26', 'Hatboro-Horsham High School, Horsham, PA', '2026-03-07', 'PAHAT', '2026pahat', 'qualifier'),
  ('Bosphorus ''26', 'Başakşehir / İstanbul, Türkiye', '2026-03-07', 'TUIS2', '2026tuis2', 'qualifier'),
  ('Alexandria VA ''26', 'Hayfield Secondary School, Alexandria, VA', '2026-03-07', 'VAALE', '2026vaale', 'qualifier'),
  ('Bonney Lake ''26', 'Bonney Lake High School, Bonney Lake, WA', '2026-03-07', 'WABON', '2026wabon', 'qualifier'),
  ('Lakeland ''26', 'Lakeland University, Plymouth, WI', '2026-03-07', 'WIPLY', '2026wiply', 'qualifier'),
  ('Space City @ League City #1 ''26', 'Clear Springs High School, League City, TX', '2026-03-08', 'TXCLE', '2026txcle', 'qualifier'),
  ('Yeditepe ''26', 'Başakşehir / İstanbul, Türkiye', '2026-03-10', 'TUIS4', '2026tuis4', 'qualifier'),
  ('Arizona North ''26', 'Northern Arizona University - Walkup Skydome, Flagstaff, AZ', '2026-03-13', 'AZFG', '2026azfg', 'qualifier'),
  ('Monterrey ''26', 'ITESM Campus Monterrey - Arena Borregos, Monterrey, Mexico', '2026-03-13', 'MXMO', '2026mxmo', 'qualifier'),
  ('Great Northern ''26', 'Alerus Center, Grand Forks, ND', '2026-03-13', 'NDGF', '2026ndgf', 'qualifier'),
  ('Finger Lakes ''26', 'Gordon Field House - Rochester Institute of Technology, Rochester, NY', '2026-03-13', 'NYRO', '2026nyro', 'qualifier'),
  ('Southern Cross ''26', 'Penrith Valley Regional Sports Centre, Cambridge Park, Australia', '2026-03-14', 'AUSC', '2026ausc', 'qualifier'),
  ('SESI Osasco ''26', 'SESI Osasco, Osasco, Brazil', '2026-03-14', 'BRSP', '2026brsp', 'qualifier'),
  ('Shanghai ''26', 'East China Normal University Minhang Campus Venue, Minhang District, China', '2026-03-14', 'CNSH', '2026cnsh', 'qualifier'),
  ('Wayne State ''26', 'Wayne State University, Detroit, MI', '2026-03-13', 'MIDTR', '2026midtr', 'qualifier'),
  ('Midland ''26', 'HH Dow High School, Midland, MI', '2026-03-13', 'MIMID', '2026mimid', 'qualifier'),
  ('Milford ''26', 'Milford High School, Highland, MI', '2026-03-13', 'MIMIL', '2026mimil', 'qualifier'),
  ('Humber Polytechnic ''26', 'Humber College, Etobicoke, ON, Canada', '2026-03-13', 'ONTOR', '2026ontor', 'qualifier'),
  ('Richland ''26', 'Lower Richland High School, Hopkins, SC', '2026-03-13', 'SCHOP', '2026schop', 'qualifier'),
  ('McAllen ''26', 'McAllen Convention Center, McAllen, TX', '2026-03-13', 'TXMCA', '2026txmca', 'qualifier'),
  ('San Antonio ''26', 'Freeman Coliseum, San Antonio, TX', '2026-03-13', 'TXSAN', '2026txsan', 'qualifier'),
  ('San Francisco ''26', 'St. Ignatius College Preparatory, San Francisco, CA', '2026-03-14', 'CASNF', '2026casnf', 'qualifier'),
  ('Silicon Valley ''26', 'Woodside High School, Woodside, CA', '2026-03-14', 'CASNV', '2026casnv', 'qualifier'),
  ('Ventura County ''26', 'Ventura College Sportsplex, Ventura, CA', '2026-03-14', 'CAVEN', '2026caven', 'qualifier'),
  ('Gwinnett ''26', 'Discovery High School, Lawrenceville, GA', '2026-03-14', 'GAGWI', '2026gagwi', 'qualifier'),
  ('North Shore ''26', 'Reading Memorial High School, Reading, MA', '2026-03-14', 'MAREA', '2026marea', 'qualifier'),
  ('Western NE ''26', 'Western New England University, Springfield, MA', '2026-03-14', 'MAWNE', '2026mawne', 'qualifier'),
  ('Pasadena MD ''26', 'Chesapeake High School, Pasadena, MD', '2026-03-14', 'MDPAS', '2026mdpas', 'qualifier'),
  ('Woodhaven ''26', 'Woodhaven High School, Brownstown Charter Twp, MI', '2026-03-14', 'MIBRO', '2026mibro', 'qualifier'),
  ('Lake City ''26', 'Lake City School, Lake City, MI', '2026-03-14', 'MILAC', '2026milac', 'qualifier'),
  ('Marysville ''26', 'Marysville High School, Marysville, MI', '2026-03-14', 'MIMAR', '2026mimar', 'qualifier'),
  ('UNC Asheville ''26', 'Kimmel Arena @ UNC Asheville, Asheville, NC', '2026-03-14', 'NCASH', '2026ncash', 'qualifier'),
  ('Granite State ''26', 'Bedford High School, Bedford, NH', '2026-03-14', 'NHBED', '2026nhbed', 'qualifier'),
  ('Seneca ''26', 'Seneca High School, Tabernacle, NJ', '2026-03-14', 'NJTAB', '2026njtab', 'qualifier'),
  ('Durham College ''26', 'Durham College, Oshawa, ON, Canada', '2026-03-14', 'ONOSH', '2026onosh', 'qualifier'),
  ('Wilsonville ''26', 'Wilsonville High School, Wilsonville, OR', '2026-03-14', 'ORWIL', '2026orwil', 'qualifier'),
  ('Glen Allen VA ''26', 'Deep Run High School, Glen Allen, VA', '2026-03-14', 'VAGLE', '2026vagle', 'qualifier'),
  ('Glacier Peak ''26', 'Glacier Peak High School, Snohomish, WA', '2026-03-14', 'WASNO', '2026wasno', 'qualifier'),
  ('Arkansas ''26', 'Ganus Activities Complex at Harding University, Searcy, AR', '2026-03-20', 'ARLI', '2026arli', 'qualifier'),
  ('Orlando ''26', 'Addition Financial Arena at the University of Central Florida, Orlando, FL', '2026-03-20', 'FLOR', '2026flor', 'qualifier'),
  ('Central Illinois ''26', 'Renaissance Coliseum - Bradley University, Peoria, IL', '2026-03-20', 'ILPE', '2026ilpe', 'qualifier'),
  ('Heartland ''26', 'Mill Valley High School, Shawnee, KS', '2026-03-20', 'KSLA', '2026ksla', 'qualifier'),
  ('Magnolia ''26', 'South Mississippi Fairgrounds, Laurel, MS', '2026-03-20', 'MSLR', '2026mslr', 'qualifier'),
  ('Long Island ''26', 'David S. Mack Sports and Exhibition Complex, Hempstead, NY', '2026-03-20', 'NYLI2', '2026nyli2', 'qualifier'),
  ('Hudson Valley ''26', 'Rockland Community College - Athletic Center, Suffern, NY', '2026-03-20', 'NYSU', '2026nysu', 'qualifier'),
  ('Buckeye ''26', 'Cleveland State University - Wolstein Center, Cleveland, OH', '2026-03-20', 'OHCL', '2026ohcl', 'qualifier'),
  ('Greater Pittsburgh ''26', 'David L. Lawrence Convention Center, Pittsburgh, PA', '2026-03-20', 'PACA', '2026paca', 'qualifier'),
  ('Smoky Mountains ''26', 'Sevierville Convention Center, Sevierville, TN', '2026-03-20', 'TNKN', '2026tnkn', 'qualifier'),
  ('Columbus GA ''26', 'Columbus Civic Center, Columbus, GA', '2026-03-20', 'GACOL', '2026gacol', 'qualifier'),
  ('Hawaii ''26', 'Saint Louis High School, Honolulu, HI', '2026-03-21', 'HIHO', '2026hiho', 'qualifier'),
  ('Belleville ''26', 'Belleville High School, Belleville, MI', '2026-03-20', 'MIBEL', '2026mibel', 'qualifier'),
  ('Muskegon ''26', 'Orchard View High School, Muskegon, MI', '2026-03-20', 'MIMUS', '2026mimus', 'qualifier'),
  ('Traverse City ''26', 'Traverse City West Senior High School, Traverse City, MI', '2026-03-20', 'MITVC', '2026mitvc', 'qualifier'),
  ('URI ''26', 'Keaney Gym, Kingston, RI', '2026-03-20', 'RIKIN', '2026rikin', 'qualifier'),
  ('Fort Worth ''26', 'Nolan Catholic High School, Fort Worth, TX', '2026-03-20', 'TXFOR', '2026txfor', 'qualifier'),
  ('Houston ''26', 'M. O. Campbell Educational Center, Houston, TX', '2026-03-20', 'TXHOU', '2026txhou', 'qualifier'),
  ('Waco ''26', 'Extraco Event Center, Waco, TX', '2026-03-20', 'TXWAC', '2026txwac', 'qualifier'),
  ('SunDome ''26', 'SunDome, State Fair Park, Yakima, WA', '2026-03-20', 'WAYAK', '2026wayak', 'qualifier'),
  ('Los Angeles ''26', 'DaVinci High School, El Segundo, CA', '2026-03-21', 'CALAS', '2026calas', 'qualifier'),
  ('Sacramento ''26', 'Pleasant Grove High School, Elk Grove, CA', '2026-03-21', 'CASAC', '2026casac', 'qualifier'),
  ('San Diego ''26', 'Francis Parker High School, San Diego, CA', '2026-03-21', 'CASND', '2026casnd', 'qualifier'),
  ('Waterbury ''26', 'Wilby High School, Waterbury, CT', '2026-03-21', 'CTWAT', '2026ctwat', 'qualifier'),
  ('Columbus IN ''26', 'Columbus East High School, Columbus, IN', '2026-03-21', 'INCOL', '2026incol', 'qualifier'),
  ('Bethesda MD ''26', 'Walt Whitman High School, Bethesda, MD', '2026-03-21', 'MDBET', '2026mdbet', 'qualifier'),
  ('Berrien Springs ''26', 'Berrien Springs High School, Berrien Springs, MI', '2026-03-21', 'MIBER', '2026miber', 'qualifier'),
  ('Jackson at Columbia ''26', 'Columbia Central High School, Brooklyn, MI', '2026-03-21', 'MIBKN', '2026mibkn', 'qualifier'),
  ('Kearsley ''26', 'Kearsley High School, Flint, MI', '2026-03-21', 'MIFLI', '2026mifli', 'qualifier'),
  ('Elon University ''26', 'Elon University, Elon, NC', '2026-03-21', 'NCELO', '2026ncelo', 'qualifier'),
  ('Wake County #2 ''26', 'Heritage High School, Wake Forest, NC', '2026-03-21', 'NCWK2', '2026ncwk2', 'qualifier'),
  ('Robbinsville ''26', 'Robbinsville High School, Trenton, NJ', '2026-03-21', 'NJROB', '2026njrob', 'qualifier'),
  ('McMaster University ''26', 'McMaster University, Hamilton, ON, Canada', '2026-03-21', 'ONHAM', '2026onham', 'qualifier'),
  ('North Bay ''26', 'Nipissing University, North Bay, ON, Canada', '2026-03-21', 'ONNOB', '2026onnob', 'qualifier'),
  ('Centennial ''26', 'William Tennent High School, Warminster, PA', '2026-03-21', 'PAWAR', '2026pawar', 'qualifier'),
  ('Chesapeake VA ''26', 'Hickory High School, Chesapeake, VA', '2026-03-21', 'VACHE', '2026vache', 'qualifier'),
  ('Sammamish ''26', 'Sammamish High School, Bellevue, WA', '2026-03-21', 'WASAM', '2026wasam', 'qualifier'),
  ('Appleton ''26', 'Appleton East High School, Appleton, WI', '2026-03-21', 'WIAPP', '2026wiapp', 'qualifier'),
  ('Iowa ''26', 'McLeod Center/UNI Dome, Cedar Falls, IA', '2026-03-27', 'IACF', '2026iacf', 'qualifier'),
  ('Midwest ''26', 'Forest View Education Center, Arlington Heights, IL', '2026-03-27', 'ILCH', '2026ilch', 'qualifier'),
  ('Minnesota 10,000 Lakes ''26', '3M Mariucci - University of Minnesota, Minneapolis, MN', '2026-03-27', 'MNMI', '2026mnmi', 'qualifier'),
  ('St. Louis ''26', 'Chaifetz Arena, St. Louis, MO', '2026-03-27', 'MOSL', '2026mosl', 'qualifier'),
  ('Laguna ''26', 'Tecnologico de Monterrey Auditorium, Torreón, Mexico', '2026-03-27', 'MXTO', '2026mxto', 'qualifier'),
  ('Haliç ''26', 'Türkiye Atletizm Federasyonu Atletizim Salonu, Bakırköy / İstanbul, Türkiye', '2026-03-26', 'TUHC', '2026tuhc', 'qualifier'),
  ('Albany ''26', 'Albany Civic Center, Albany, GA', '2026-03-27', 'GAALB', '2026gaalb', 'qualifier'),
  ('Idaho ''26', 'Ford Idaho Center, Nampa, ID', '2026-03-27', 'IDBO', '2026idbo', 'qualifier'),
  ('Lafayette ''26', 'Jefferson High School, Lafayette, IN', '2026-03-27', 'INLAF', '2026inlaf', 'qualifier'),
  ('LSSU ''26', 'Lake Superior State University, Sault Ste. Marie, MI', '2026-03-27', 'MILSU', '2026milsu', 'qualifier'),
  ('West Michigan ''26', 'Grand Valley State University, Allendale, MI', '2026-03-27', 'MIWMI', '2026miwmi', 'qualifier'),
  ('University of Waterloo ''26', 'University of Waterloo, Waterloo, ON, Canada', '2026-03-27', 'ONWAT', '2026onwat', 'qualifier'),
  ('Clackamas Academy ''26', 'Clackamas Academy of Industrial Science, Oregon City, OR', '2026-03-27', 'ORORE', '2026orore', 'qualifier'),
  ('Hartsville ''26', 'Coker University, Hartsville, SC', '2026-03-27', 'SCHAR', '2026schar', 'qualifier'),
  ('Central Valley ''26', 'Buchanan High School, Clovis, CA', '2026-03-28', 'CACLV', '2026caclv', 'qualifier'),
  ('Glendale ''26', 'Glendale High School, Glendale, CA', '2026-03-28', 'CAGLE', '2026cagle', 'qualifier'),
  ('Pinnacles ''26', 'Hollister High School, Hollister, CA', '2026-03-28', 'CAPIN', '2026capin', 'qualifier'),
  ('San Gabriel Valley ''26', 'Don Bosco Technical Institute, Rosemead, CA', '2026-03-28', 'CASGV', '2026casgv', 'qualifier'),
  ('Hartford ''26', 'Hartford Public High School, Hartford, CT', '2026-03-28', 'CTHAR', '2026cthar', 'qualifier'),
  ('Greater Boston ''26', 'Revere High School, Revere, MA', '2026-03-28', 'MABOS', '2026mabos', 'qualifier'),
  ('Severn MD ''26', 'Severn Run High School, Severn, MD', '2026-03-28', 'MDSEV', '2026mdsev', 'qualifier'),
  ('Battle Creek ''26', 'Battle Creek Central High School, Battle Creek, MI', '2026-03-28', 'MIBAT', '2026mibat', 'qualifier'),
  ('Mason ''26', 'Mason High School, Mason, MI', '2026-03-28', 'MIMAS', '2026mimas', 'qualifier'),
  ('Saline ''26', 'Saline High School, Saline, MI', '2026-03-28', 'MISAL', '2026misal', 'qualifier'),
  ('Troy ''26', 'Troy Athens High School, Troy, MI', '2026-03-28', 'MITRY', '2026mitry', 'qualifier'),
  ('UNC Pembroke ''26', 'Jones Center @ UNC Pembroke, Pembroke, NC', '2026-03-28', 'NCPEM', '2026ncpem', 'qualifier'),
  ('UNH ''26', 'Whittemore Center Arena, Durham, NH', '2026-03-28', 'NHDUR', '2026nhdur', 'qualifier'),
  ('Mount Olive ''26', 'Mount Olive High School, Flanders, NJ', '2026-03-28', 'NJFLA', '2026njfla', 'qualifier'),
  ('Georgian College ''26', 'Georgian College, Barrie, ON, Canada', '2026-03-28', 'ONBAR', '2026onbar', 'qualifier'),
  ('Bensalem ''26', 'Bensalem Township High School, Bensalem, PA', '2026-03-28', 'PABEN', '2026paben', 'qualifier'),
  ('Farmersville ''26', 'Farmersville Arena, Farmersville, TX', '2026-03-28', 'TXFAR', '2026txfar', 'qualifier'),
  ('Manor ''26', 'Manor Senior High School, Manor, TX', '2026-03-28', 'TXMAN', '2026txman', 'qualifier'),
  ('Blacksburg VA ''26', 'Blacksburg High School, Blacksburg, VA', '2026-03-28', 'VABLA', '2026vabla', 'qualifier'),
  ('Auburn ''26', 'Auburn High School, Auburn, WA', '2026-03-28', 'WAAHS', '2026waahs', 'qualifier'),
  ('Mukwonago ''26', 'Mukwonago High School, Mukwonago, WI', '2026-03-28', 'WIMUK', '2026wimuk', 'qualifier'),
  ('Marmara ''26', 'Türkiye Atletizm Federasyonu Atletizim Salonu, Bakırköy / İstanbul, Türkiye', '2026-03-29', 'TUIS3', '2026tuis3', 'qualifier'),
  ('Avrasya ''26', 'Türkiye Atletizm Federasyonu Atletizim Salonu, Bakırköy / İstanbul, Türkiye', '2026-04-01', 'TUIS5', '2026tuis5', 'qualifier'),
  ('Bayou ''26', 'Pontchartrain Center, Kenner, LA', '2026-04-03', 'LAKE', '2026lake', 'qualifier'),
  ('Minnesota North Star ''26', '3M Mariucci - University of Minnesota, Minneapolis, MN', '2026-04-03', 'MNUM', '2026mnum', 'qualifier'),
  ('City of Fountains ''26', 'Park Hill South High School, Riverside, MO', '2026-04-03', 'MOSE', '2026mose', 'qualifier'),
  ('Miami Valley ''26', 'Xavier University - Cintas Center, Cincinnati, OH', '2026-04-03', 'OHMV', '2026ohmv', 'qualifier'),
  ('Green Country ''26', 'Expo Square Pavilion, Tulsa, OK', '2026-04-03', 'OKTU', '2026oktu', 'qualifier'),
  ('Aerospace Valley ''26', 'Eastside High School, Lancaster, CA', '2026-04-03', 'CAASV', '2026caasv', 'qualifier'),
  ('Contra Costa ''26', 'Pittsburg High School, Pittsburg, CA', '2026-04-03', 'CACAC', '2026cacac', 'qualifier'),
  ('East Bay ''26', 'Berkeley High School, Berkeley, CA', '2026-04-03', 'CAETB', '2026caetb', 'qualifier'),
  ('Orange County ''26', 'Capistrano Valley High School, Mission Viejo, CA', '2026-04-03', 'CAOEC', '2026caoec', 'qualifier'),
  ('Gainesville ''26', 'Riverside Preparatory Academy, Gainesville, GA', '2026-04-03', 'GAGAI', '2026gagai', 'qualifier'),
  ('Washington ''26', 'Washington High School, Washington, IN', '2026-04-03', 'INWAS', '2026inwas', 'qualifier'),
  ('Livonia ''26', 'Churchill High School, Livonia, MI', '2026-04-03', 'MILIV', '2026miliv', 'qualifier'),
  ('Troy #2 ''26', 'Troy Athens High School, Troy, MI', '2026-04-03', 'MITR2', '2026mitr2', 'qualifier'),
  ('Philadelphia ''26', 'Abraham Lincoln High School, Philadelphia, PA', '2026-04-03', 'PAPHI', '2026paphi', 'qualifier'),
  ('Amarillo ''26', 'Amarillo Civic Center, Amarillo, TX', '2026-04-03', 'TXAMA', '2026txama', 'qualifier'),
  ('Space City @ Friendswood #2 ''26', 'Clear Brook High School, Friendswood, TX', '2026-04-03', 'TXCL2', '2026txcl2', 'qualifier'),
  ('Dripping Springs ''26', 'Dripping Springs High School, Dripping Springs, TX', '2026-04-03', 'TXDRI', '2026txdri', 'qualifier'),
  ('UVM ''26', 'Patrick Gym, Burlington, VT', '2026-04-03', 'VTBUR', '2026vtbur', 'qualifier'),
  ('Seven Rivers ''26', 'La Crosse Center, La Crosse, WI', '2026-04-03', 'WILAX', '2026wilax', 'qualifier'),
  ('WPI ''26', 'Harrington Auditorium, Worcester, MA', '2026-04-04', 'MAWOR', '2026mawor', 'qualifier'),
  ('Gotham ''26', 'Fort Washington Armory - NYC, New York, NY', '2026-04-07', 'NYN2', '2026nyn2', 'qualifier'),
  ('Ankara ''26', 'Etimesgut / Ankara, Türkiye', '2026-04-08', 'TUAK', '2026tuak', 'qualifier'),
  ('Rocket City ''26', 'Von Braun Center, Huntsville, AL', '2026-04-10', 'ALHU', '2026alhu', 'qualifier'),
  ('Denver ''26', 'University of Denver - Daniel L. Ritchie Center, Denver, CO', '2026-04-10', 'CODE', '2026code', 'qualifier'),
  ('South Florida ''26', 'Watsco Center - University of Miami, Coral Gables, FL', '2026-04-10', 'FLWP', '2026flwp', 'qualifier'),
  ('Peachtree ''26', 'Mercer University Macon - Hawkins Arena, Macon, GA', '2026-04-10', 'GACMP', '2026gacmp', 'district_championship'),
  ('Minnesota Granite City ''26', 'River''s Edge Convention Center, St. Cloud, MN', '2026-04-10', 'MNMI2', '2026mnmi2', 'qualifier'),
  ('Greater Kansas City ''26', 'Lee''s Summit North High School, Lee''s Summit, MO', '2026-04-10', 'MOKC', '2026mokc', 'qualifier'),
  ('Las Vegas ''26', 'UNLV - Thomas & Mack Center, Las Vegas, NV', '2026-04-10', 'NVLV', '2026nvlv', 'qualifier'),
  ('Pacific Northwest ''26', 'Eastern Washington University, Cheney, WA', '2026-04-10', 'PNCMP', '2026pncmp', 'district_championship'),
  ('Festival de Robotique ''26', 'Bombardier, Dorval, QC, Canada', '2026-04-10', 'QCMO', '2026qcmo', 'qualifier'),
  ('California Northern ''26', 'Cow Palace Arena & Event Center, Daly City, CA', '2026-04-11', 'CANCMP', '2026cancmp', 'district_championship'),
  ('California Southern ''26', 'Anaheim Convention Center Arena, Anaheim, CA', '2026-04-11', 'CASCMP', '2026cascmp', 'district_championship'),
  ('Chesapeake ''26', 'Virginia State University Multipurpose Center, Petersburg, VA', '2026-04-11', 'CHCMP', '2026chcmp', 'district_championship'),
  ('Ferris State ''26', 'Ferris State University, Big Rapids, MI', '2026-04-10', 'MIBIG', '2026mibig', 'qualifier'),
  ('Escanaba ''26', 'Escanaba Jr/Sr High School, Escanaba, MI', '2026-04-10', 'MIESC', '2026miesc', 'qualifier'),
  ('Kentwood ''26', 'East Kentwood High School, Kentwood, MI', '2026-04-10', 'MIKEN', '2026miken', 'qualifier'),
  ('North Carolina ''26', 'Greensboro Special Events Center, Greensboro, NC', '2026-04-11', 'NCCMP', '2026nccmp', 'district_championship'),
  ('New York City ''26', 'Fort Washington Armory - NYC, New York, NY', '2026-04-11', 'NYNY', '2026nyny', 'qualifier'),
  ('Windsor Essex Great Lake ''26', 'University of Windsor, Windsor, ON, Canada', '2026-04-10', 'ONWIN', '2026onwin', 'qualifier'),
  ('South Carolina ''26', 'Civic Center of Anderson, Anderson, SC', '2026-04-10', 'SCCMP', '2026sccmp', 'district_championship'),
  ('Fenton ''26', 'Fenton High School, Fenton, MI', '2026-04-11', 'MIFEN', '2026mifen', 'qualifier'),
  ('Montgomery ''26', 'Montgomery Township High School, Skillman, NJ', '2026-04-11', 'NJSKI', '2026njski', 'qualifier'),
  ('Niagara College ''26', 'Niagara College, Welland, ON, Canada', '2026-04-11', 'ONWEL', '2026onwel', 'qualifier'),
  ('Başkent ''26', 'Etimesgut / Ankara, Türkiye', '2026-04-11', 'TUAK2', '2026tuak2', 'qualifier'),
  ('Tallahassee ''26', 'Alfred Lawson Jr Multipurpose Center - Florida A&M University, Tallahassee, FL', '2026-04-17', 'FLTA', '2026flta', 'qualifier'),
  ('Mid-Atlantic ''26', 'Lehigh University - Stabler Arena, Bethlehem, PA', '2026-04-17', 'MRCMP', '2026mrcmp', 'district_championship'),
  ('Burns ''26', 'Eastern States Exposition, West Springfield, MA', '2026-04-17', 'NECMP1', '2026necmp1', 'district_championship'),
  ('Newsom ''26', 'Eastern States Exposition, West Springfield, MA', '2026-04-17', 'NECMP2', '2026necmp2', 'district_championship'),
  ('New York Tech Valley ''26', 'MVP Arena, Albany, NY', '2026-04-17', 'NYTR', '2026nytr', 'qualifier'),
  ('Texas Mercury ''26', 'NRG Arena, Houston, TX', '2026-04-17', 'TXCMP1', '2026txcmp1', 'district_championship'),
  ('Texas Apollo ''26', 'NRG Arena, Houston, TX', '2026-04-17', 'TXCMP2', '2026txcmp2', 'district_championship'),
  ('Michigan DTE Energy Foundation ''26', 'Saginaw Valley State University, University Center, MI', '2026-04-17', 'MICMP1', '2026micmp1', 'district_championship'),
  ('Michigan Consumers Energy Foundation ''26', 'Saginaw Valley State University, University Center, MI', '2026-04-17', 'MICMP2', '2026micmp2', 'district_championship'),
  ('Michigan Hemlock Semiconductor ''26', 'Saginaw Valley State University, University Center, MI', '2026-04-17', 'MICMP3', '2026micmp3', 'district_championship'),
  ('Michigan Aptiv Foundation ''26', 'Saginaw Valley State University, University Center, MI', '2026-04-17', 'MICMP4', '2026micmp4', 'district_championship'),
  ('Ontario Science ''26', 'Niagara Falls Convention Centre, Niagara Falls, ON, Canada', '2026-04-18', 'ONCMP1', '2026oncmp1', 'district_championship'),
  ('Ontario Technology ''26', 'Niagara Falls Convention Centre, Niagara Falls, ON, Canada', '2026-04-18', 'ONCMP2', '2026oncmp2', 'district_championship'),
  ('Utah ''26', 'Maverik Center, West Valley City, UT', '2026-04-17', 'UTWV', '2026utwv', 'qualifier'),
  ('Indiana ''26', 'Indiana State Fairgrounds Blue Ribbon Pavillion, Indianapolis, IN', '2026-04-18', 'INCMP', '2026incmp', 'district_championship'),
  ('Wisconsin ''26', 'Brookfield East High School, Brookfield, WI', '2026-04-18', 'WICMP', '2026wicmp', 'district_championship'),
  ('Michigan Finals ''26', 'Saginaw Valley State University, University Center, MI', '2026-04-18', 'MICMP', '2026micmp', 'district_championship'),
  ('NE Champs Finals ''26', 'Eastern States Exposition, West Springfield, MA', '2026-04-18', 'NECMP', '2026necmp', 'district_championship'),
  ('Texas Finals ''26', 'NRG Arena, Houston, TX', '2026-04-18', 'TXCMP', '2026txcmp', 'district_championship'),
  ('Ontario Finals ''26', 'Niagara Falls Convention Centre, Niagara Falls, ON, Canada', '2026-04-19', 'ONCMP', '2026oncmp', 'district_championship'),
  ('Archimedes ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'ARCHIMEDES', '2026arc', 'championship'),
  ('Curie ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'CURIE', '2026cur', 'championship'),
  ('Daly ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'DALY', '2026dal', 'championship'),
  ('Galileo ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'GALILEO', '2026gal', 'championship'),
  ('Hopper ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'HOPPER', '2026hop', 'championship'),
  ('Johnson ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'JOHNSON', '2026joh', 'championship'),
  ('Milstein ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'MILSTEIN', '2026mil', 'championship'),
  ('Newton ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'NEWTON', '2026new', 'championship'),
  ('Einstein ''26', 'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'CMPTX', '2026cmptx', 'championship'),
  ('Israel District 1 ''26', 'Arena Natanya, Natanya, Israel', '2026-06-28', 'ISDE1', '2026isde1', 'qualifier'),
  ('Israel District 2 ''26', 'Arena Natanya, Natanya, Israel', '2026-06-30', 'ISDE2', '2026isde2', 'qualifier'),
  ('Israel Championship ''26', 'Enerbox, Hadera, Israel', '2026-07-07', 'ISCMP', '2026iscmp', 'district_championship')
) as v(name, location, event_date, frc_event_code, tba_event_key, event_tier);

-- True if the table already has this event: a row with its TBA key, or with its FRC code in the
-- same season. The season comes from the row's TBA key, or its date when it has no key.
-- Re-checked on every call, so rows linked in section 3 count straight away.
create or replace function pg_temp.has_event(p_tba text, p_frc text) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.events e
    where lower(e.tba_event_key) = p_tba
       or (upper(e.frc_event_code) = p_frc
           and coalesce(substring(e.tba_event_key from '^[0-9]{4}')::int,
                        extract(year from e.event_date)::int) = 2026))
$$;


-- =====================================================================
-- 3. Link hand-added rows: same name, no FRC/TBA codes yet. Only when
--    nothing else already has those codes, and only one row per name.
-- =====================================================================
update public.events e
set frc_event_code = i.frc_event_code,
    tba_event_key  = i.tba_event_key,
    event_tier     = i.event_tier
from import_2026 i
where e.name = i.name
  and e.frc_event_code is null
  and e.tba_event_key is null
  and not pg_temp.has_event(i.tba_event_key, i.frc_event_code)
  and (select count(*) from public.events d where d.name = i.name) = 1;


-- =====================================================================
-- 4. Add every event that isn't in the table yet
-- =====================================================================
insert into public.events (name, location, event_date, frc_event_code, tba_event_key, event_tier)
select i.name, i.location, i.event_date, i.frc_event_code, i.tba_event_key, i.event_tier
from import_2026 i
where not pg_temp.has_event(i.tba_event_key, i.frc_event_code)
order by i.event_date, i.name;


-- =====================================================================
-- 5. Check query. Every count should read 0 except events_2026 (213, plus
--    any 2026 off-season rows) and missing (0 once the import has run).
-- =====================================================================
select
  (select count(*) from public.events
    where coalesce(substring(tba_event_key from '^[0-9]{4}')::int, extract(year from event_date)::int) = 2026)
    as events_2026,
  (select count(*) from import_2026 i
    where not pg_temp.has_event(i.tba_event_key, i.frc_event_code))
    as missing,
  (select count(*) from (select lower(tba_event_key) from public.events where tba_event_key is not null
                         group by 1 having count(*) > 1) d)
    as duplicate_tba_keys,
  (select count(*) from (select upper(frc_event_code),
                                coalesce(substring(tba_event_key from '^[0-9]{4}')::int, extract(year from event_date)::int)
                         from public.events where frc_event_code is not null
                         group by 1, 2 having count(*) > 1) d)
    as duplicate_frc_codes,
  (select count(*) from (select name from public.events group by 1 having count(*) > 1) d)
    as duplicate_names;
