<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>

# SofaBuffers — Corelib-Implementierungsplan

<b>Structured Objects For Anyone</b><br>
<i>... so optimized, feels amazing.</i>

Dieses Dokument spezifiziert, **was SofaBuffers ist und wie es funktioniert — unabhängig von
jeder Programmiersprache**. Ein Mensch *oder eine KI* kann es als alleinige Wahrheitsquelle
verwenden, um eine neue **Core-Library-Implementierung (`corelib-<lang>`)** zu erstellen,
die zu jeder bestehenden byte-für-byte kompatibel ist.

**Wie dieses Dokument zu lesen ist**

* **Normativer** Text verwendet die Schlüsselwörter unten. Alles andere ist Kontext —
  Hintergrund, Begründung oder Beispiel. Nur die Schlüsselwörter erzeugen eine Pflicht.

  | Schlüsselwort | Bedeutung |
  |---|---|
  | **MUSS**, **ERFORDERLICH** (MUST, REQUIRED) | Eine absolute Anforderung. Eine Implementierung, die das nicht tut, ist **nicht konform**, egal was sie sonst richtig macht. |
  | **DARF NICHT** (MUST NOT) | Ein absolutes Verbot. Gleiches Gewicht wie MUSS. |
  | **SOLLTE** (SHOULD) | Es kann in besonderen Situationen triftige Gründe geben, anders zu handeln — aber erst, nachdem die vollen Konsequenzen verstanden und abgewogen wurden. Ein Port, der abweicht, **hält die Abweichung in seinem README fest** — eine Zeile, als Fakt formuliert; §9.0.1 gilt weiterhin. |
  | **SOLLTE NICHT** (SHOULD NOT) | Dasselbe in der Verneinung: Das Verhalten ist unerwünscht, und eine Abweichung braucht einen festgehaltenen Grund. |
  | **DARF**, **OPTIONAL** (MAY, OPTIONAL) | Wirklich optional. Ein Port, der es implementiert, und einer, der es nicht tut, sind **beide konform** — und keiner darf die Wahl des anderen voraussetzen. |

  Sinn wie in RFC 2119 / BCP 14, aber diese Tabelle ist hier die maßgebliche Definition —
  wo beide sich unterscheiden, gewinnt diese Tabelle. **Die Schlüsselwörter sind nur in
  Großschreibung normativ.** Kleingeschriebenes *muss* / *sollte* / *darf* ist gewöhnliche
  Prosa und erzeugt für sich nie eine Pflicht; wo es eine wiedergibt, gilt die
  großgeschriebene Regel des Kapitels, auf das es zeigt.

  Zwei Konventionen, die dieses Dokument ergänzt:

  * Eine mit **(normativ)** markierte Überschrift bedeutet: Jede Regel darunter bindet —
    ob der einzelne Satz ein Schlüsselwort wiederholt oder nicht.
  * Wo eine Regel nur für manche Targets gilt, steht die Ausnahme **bei** der Regel —
    niemals angenommen. Steht keine Ausnahme da, gibt es keine.
* Jede Regel steht **einmal**, in einem Kapitel, und wird überall sonst per `§` referenziert.
  Wenn zwei Stellen dieselbe Regel zu nennen scheinen, ist die normative die, deren
  Überschrift das Thema benennt.
* Schichtgrenzen — weil hier die meisten Fehler passieren:
  * **dieses Dokument** — die Corelib: Wire-Bytes, Streaming, der API-Vertrag.
  * [`MESSAGE_SPEC.md`](./MESSAGE_SPEC.md) — die Message-Schicht: wie Schematypen auf den
    Draht abgebildet werden, kanonische Kodierung, Schema-Schranken.
  * **SofaBuffers ARCHITECTURE** (im `generator`) — die generierte Schicht: was generierter
    Code tut, Receiver-Cap-Werte, Allokationsform.
  * [`BENCH_SPEC.md`](BENCH_SPEC.md) — Benchmark-Workloads, Zeitmessung, Ausgabeformat.
* **Wenn dieses Dokument und die gemeinsamen Testvektoren sich widersprechen, gewinnen die
  Testvektoren.**

**Inhalt**

| § | Thema |
|---|---|
| 1 | Die Idee hinter dem Protokoll |
| 2 | Referenz-Repositories und die gemeinsame Testvektor-Wahrheitsquelle |
| 3 | Kernkonzepte — Felder, IDs, Scopes, Sequences |
| 4 | Das vollständige binäre Wire-Format (Byte-Ebene) |
| 5 | Das Streaming-Modell und sprachidiomatische Muster |
| 6 | Der sprachunabhängige API-Vertrag, einschließlich der Generated-Object-Schicht |
| 7 | Verpflichtende Unit-Tests |
| 8 | Die `assets/`-Anforderung |
| 9 | Das README-Format |
| 10 | Performance-Tests (`perf` + `bench`) |
| 11 | Dev-Container |
| 12 | GitHub-Actions-Workflows |
| 13 | Konformitäts-Checkliste |

---

## 1. Die Idee

SofaBuffers ist ein **kompaktes, selbstbeschreibendes, TLV-artiges Binärformat** für
strukturierte Nachrichten — vom Zweck her vergleichbar mit Protocol Buffers, aber um eine
einzige harte Randbedingung herum gebaut:

> **Alles muss streambar sein.**
> Serialisierung und Deserialisierung arbeiten **in beliebig kleinen Chunks**, ohne jemals
> die ganze Nachricht im Speicher zu halten.

Diese Randbedingung treibt jede weitere Entscheidung:

* **Kein Längenpräfix über die Nachricht.** Eine Nachricht ist ein flacher Strom aus
  Feldern. Sequences werden durch explizite *Start*- und *Ende*-Marker begrenzt, nie durch
  eine Byte-Anzahl — ein Encoder kann eine verschachtelte Struktur ausgeben, **ohne ihre
  endgültige Größe zu kennen**.
* **Feldweise Verarbeitung.** Jedes Feld trägt seinen eigenen Typ und, wo nötig, seine
  Länge. Ein Decoder kann auf ein Feld reagieren, sobald sein Header eintrifft — noch bevor
  die Nutzlast da ist.
* **Minimaler Overhead, eine Kopie.** Der Codec schreibt in den Puffer, den der Aufrufer
  installiert hat, und kopiert jeden dekodierten Wert in das Ziel, das der Aufrufer
  bereitgestellt hat — nie ein geliehener Slice, nie eine View (§6.7). Ein Speichermodell,
  auf jedem Pfad und in jeder Sprache.
* **Ein heap-freier Codec, überall — nicht nur wo das Target es verlangt.** Der Codec
  allokiert überhaupt nichts (§6.6): Er läuft auf Aufrufer-eigenem Speicher fester Größe,
  auf einem Server genauso wie auf einem Mikrocontroller. Dynamischer Speicher lebt in der
  generierten Schicht und in den statischen Helfern neben dem Codec — nie in ihm.
* **Kleine-Werte-Bevorzugung.** Ganzzahlen sind varint-kodiert, häufige kleine Werte kosten
  also ein Byte. Das 3-Bit-Typ-Tag ist *in* das Feld-ID-Varint gepackt, ein typischer
  kleiner Feld-Header ist damit ein einziges Byte.

Die Kodierungskosten der Typen wurden so gewählt, dass sie der durchschnittlichen
Feldtyp-Nutzung anderer Message-Formate (JSON, Protocol Buffers) entsprechen — der Overhead
ist für die häufigsten Typen am geringsten.

---

## 2. Referenz-Repositories (Quell-Eingaben)

| Repository | Sprache | Rolle |
|------------|---------|-------|
| [`documentation`](https://github.com/sofa-buffers/documentation) | — | Format-Spezifikation (diese Datei, `MESSAGE_SPEC.md`, `BENCH_SPEC.md`), Branding-Assets |
| [`corelib-c-cpp`](https://github.com/sofa-buffers/corelib-c-cpp) | C99 / C++20 | C/C++ embedded — **und die Wahrheitsquelle der gemeinsamen Testvektoren** |
| [`corelib-cpp`](https://github.com/sofa-buffers/corelib-cpp) | C++20 | C/C++ high speed |
| [`corelib-rs-no-std`](https://github.com/sofa-buffers/corelib-rs-no-std) | Rust `no_std` | Rust embedded |
| [`corelib-rs`](https://github.com/sofa-buffers/corelib-rs) | Rust | Rust high speed |
| [`corelib-py`](https://github.com/sofa-buffers/corelib-py) | Python | Python high speed |
| [`corelib-ts`](https://github.com/sofa-buffers/corelib-ts) | TypeScript | TypeScript high speed |
| [`corelib-go`](https://github.com/sofa-buffers/corelib-go) | Go | Go high speed |
| [`corelib-java`](https://github.com/sofa-buffers/corelib-java) | Java | Java high speed |
| [`corelib-cs`](https://github.com/sofa-buffers/corelib-cs) | C# | C# high speed |
| [`generator`](https://github.com/sofa-buffers/generator) | — | Schema → Code-Generator; besitzt das ARCHITECTURE-Dokument |

**Gemeinsame Artefakte** (werden in jedes neue Repo kopiert — wohin, sagt §8):

| Artefakt | Aus | Zweck |
|---|---|---|
| `sofabuffers_logo.png`, `sofabuffers_icon.png` | `documentation/assets/` | Branding, vom README-Header verwendet |
| `test_vectors.json` | `corelib-c-cpp/assets/` | Die sprachunabhängige Konformitäts-Suite |
| `test_vectors_README.md` | `corelib-c-cpp/assets/` | Die **maßgebliche** Beschreibung des Dateiformats |

`corelib-c-cpp` **generiert** die Vektoren. Niemals eine abweichende Kopie von Hand
schreiben. Raw-Links:
<https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors.json>
·
<https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors_README.md>

---

## 3. Kernkonzepte

Eine **Nachricht** ist ein geordneter Strom aus **Feldern**. Es gibt keinen Umschlag und
keinen Gesamtlängen-Header.

| Begriff | Definition |
|---|---|
| **Feld** | Eine `(ID, Typ, Nutzlast)`-Einheit. |
| **ID** | Eine vom Schema-Autor gewählte Ganzzahl, die das Feld in seinem aktuellen Scope identifiziert. Bereich `0 .. 2.147.483.647` (§6.2). Eindeutig innerhalb eines Scopes; darf sich in verschiedenen Scopes wiederholen. |
| **Typ** | Einer von 8 Wire-Typen, ein 3-Bit-Tag (§4.3). |
| **Sequence** | Ein Wire-Konstrukt, das einen frischen ID-Scope öffnet — **und sonst nichts**. Geöffnet durch ein *Sequence-Start*-Feld, geschlossen durch einen *Sequence-Ende*-Marker (§4.9). |
| **Scope** | Der ID-Namensraum, den eine Sequence öffnet. Kind-IDs kollidieren nie mit Eltern-IDs. |

Zwei Konsequenzen, auf denen der Rest dieses Dokuments aufbaut:

* **Eine Sequence trägt keine Typsemantik.** Die Message-Schicht baut verschachtelte
  Strukturen, dynamische Arrays, Arrays variabel langer Elemente und getaggte Unions auf
  diesem einen Primitiv auf. Wie jeder Schematyp auf Sequences abgebildet wird, definiert
  [`MESSAGE_SPEC.md`](./MESSAGE_SPEC.md) §4–§5, **nicht dieses Dokument** — für eine
  Corelib sind alle nur Sequences.
* **Jedes Feld ist allein aus seinem Header überspringbar.** Ein Decoder, der ein Feld —
  oder eine ganze Sub-Sequence — nicht will, kann es nur mit Header-Informationen
  konsumieren.

---

## 4. Binäres Wire-Format

**Alles ist little-endian.** Varints sind LEB128-artig (niederwertigste Gruppe zuerst,
inhärent little-endian); IEEE-754-Floats werden little-endian abgelegt. Es gibt nirgends
Big-Endian-Felder.

### 4.1 Varint-Kodierung

Jede Ganzzahl im Format — Feld-IDs, Längen, Zähler und Integer-Werte, unabhängig von der
deklarierten Bitbreite — ist ein **vorzeichenloses LEB128-artiges Varint**:

* Der Wert wird in 7-Bit-Gruppen zerlegt, niederwertigste zuerst;
* jedes Byte trägt 7 Nutzbits in seinen niederen Bits;
* Bit `0x80` ist das **Fortsetzungs-Flag**: gesetzt = weitere Bytes folgen, gelöscht =
  letztes Byte.

```
Wert 0        -> 0x00        Wert 128      -> 0x80 0x01
Wert 1        -> 0x01        Wert 300      -> 0xAC 0x02
Wert 127      -> 0x7F        Wert 16384    -> 0x80 0x80 0x01
```

Ein Decoder akkumuliert in ein mindestens 64-Bit-Register und schiebt pro Byte um 7.

#### 4.1.1 Kein Wert vor dem letzten Byte (normativ)

Ein Varint hat **keinen Wert**, bis das Byte mit gelöschtem Fortsetzungs-Flag eintrifft.

* Ein Decoder **DARF** keinen Teil eines unvollständigen Varints auswerten — weder ein
  gepacktes Teilfeld noch eine partielle Größe.
* Er **DARF** einen solchen Teil **NICHT** in ein Ergebnis einfließen lassen — **auch wenn
  diese Bits arithmetisch bereits feststehen**.
* Bis das Varint endet, ist das Konstrukt, zu dem es gehört, `INCOMPLETE` (§5.2).

Die Bits sind tatsächlich lesbar — deshalb muss die Regel ausgesprochen werden: Jedes
weitere Byte trägt ein Vielfaches von 128 bei, und 128 ist durch 8 teilbar, also stehen
**die niederen 3 Bits jedes Varints mit seinem ersten Byte fest**. Beide gepackten Wörter
dieses Formats liegen dort:

| Wort | früh festgelegt | liefert seinen Wert aber erst, wenn |
|---|---|---|
| Feld-Header (§4.3) | Wire-Typ | das Header-Varint endet |
| `fixlen_word` (§4.6) | Fixlen-Subtyp | dieses Varint endet |

Eine Nachricht, die innerhalb eines `fixlen_word` endet, ist also `INCOMPLETE` — auch wenn
die festgelegten Bits bereits einen **reservierten Subtyp** `0x4`–`0x7` tragen, und auch
wenn die Feld-ID eine Schema-Schranke verletzen würde (MESSAGE_SPEC §7.1), sobald der Subtyp
bestätigt hätte, dass das Feld das deklarierte ist (MESSAGE_SPEC §7.3). Diese Prüfungen sind
nur auf dem vollständigen Wort entscheidbar.

*Warum:* Das Ergebnis darf nicht davon abhängen, wie weit die Varint-Schleife eines
Decoders zufällig abrollt. Frühes Hineinschauen zerlegt ein Wort in zwei
Entscheidungspunkte — eine Push-Oberfläche, die das vollendete Wort meldet, und eine
Pull-Oberfläche, die sein erstes Byte liest, kämen für dieselben Bytes zu verschiedenen
Urteilen. Genau die Chunk-Grenzen-Empfindlichkeit, die §7.2 Punkt 4 abfangen soll. Das
schwächt §5.2s `INVALID`-über-`INCOMPLETE`-Vorrang nicht: Der ordnet Konstrukte, die der
Decoder tatsächlich gelesen hat — ein unfertiges Varint ist keines.

#### 4.1.2 Minimalität beim Encode, Toleranz beim Decode (normativ)

* Ein Encoder **MUSS** jedes Varint in seiner **minimalen Form** ausgeben — den wenigsten
  Bytes, die den Wert darstellen. (`5` ist `0x05`, niemals `0x85 0x00`.) Das ist das
  Byte-Gesicht der Ein-kanonisches-Encoding-Regel, MESSAGE_SPEC §2.
* Ein Decoder **MUSS** ein nicht-minimales Varint innerhalb der 64-Bit-Schranke unten
  **akzeptieren**, zu dem Wert dekodieren, den es bezeichnet, und — da jedes Re-Encode
  kanonisch ist — beim Re-Encode die minimale Form ausgeben.
* Eine nicht-minimale Kodierung ist deshalb **nicht** `INVALID` (§5.2); sie wird
  wegnormalisiert.
* Das gilt überall, wo ein Varint auftritt: Feld-Header, `fixlen_word`s, Element-Zähler,
  Element-Werte und innerhalb übersprungener Felder.

#### 4.1.3 Die 64-Bit-Schranke (normativ)

Eine Varint-Kodierung **überschreitet den 64-Bit-Wertebereich** — `INVALID` (§5.2) — genau
dann, wenn:

* sie länger als **10 Bytes** ist, **oder**
* irgendein Nutzbit auf Bitposition ≥ 64 fiele (ein zehntes Byte mit Nutzlast über `0x01`).

Beide Prüfungen gelten der **Kodierung**, nicht dem dekodierten Wert: Eine 11-Byte-Kodierung
ist `INVALID`, auch wenn ihre überzähligen Bytes null sind, und ein Decoder **DARF**
überlaufende hohe Bits **NICHT** stillschweigend verwerfen.

### 4.2 Zick-Zack-Kodierung (nur vorzeichenbehaftete Ganzzahlen)

Vorzeichenbehaftete Ganzzahlen werden per Zick-Zack auf vorzeichenlose abgebildet und dann
varint-kodiert, damit kleine negative Werte klein bleiben:

```
encode(n) = (n << 1) ^ (n >> (bitbreite-1))      // arithmetischer Shift
decode(u) = (u >> 1) ^ -(u & 1)

 0 -> 0      -1 -> 1      1 -> 2      -2 -> 3      2 -> 4 ...
```

Für die Transformation **64-Bit-Breite** verwenden; Werte sind `int64`-Domäne.

### 4.3 Feld-Header: ID + Typ

Jedes Feld beginnt mit einem Varint, das ID und ein 3-Bit-Typ-Tag packt:

```
header_varint = (id << 3) | typ
```

Die Tag-Werte sind **normativ**:

| Bits | Wert | Wire-Typ | Kapitel |
|---|---|---|---|
| `0b000` | 0x0 | vorzeichenlose Ganzzahl (Varint) | §4.4 |
| `0b001` | 0x1 | vorzeichenbehaftete Ganzzahl (Zick-Zack-Varint) | §4.5 |
| `0b010` | 0x2 | Fixlen-Wert | §4.6 |
| `0b011` | 0x3 | Array vorzeichenloser Ganzzahlen | §4.7 |
| `0b100` | 0x4 | Array vorzeichenbehafteter Ganzzahlen | §4.7 |
| `0b101` | 0x5 | Array von Fixlen-Werten | §4.8 |
| `0b110` | 0x6 | Sequence-Start | §4.9 |
| `0b111` | 0x7 | Sequence-Ende | §4.9 |

### 4.4 Vorzeichenlose Ganzzahl (Typ `0b000`)

```
[ header_varint ] [ wert_varint ]
```

Beispiele: ID `0`, Wert `0` → `00 00`. ID `0`, Wert `127` → `00 7f`.

**Booleans haben keinen eigenen Wire-Typ (normativ).** Ein Boolean ist eine vorzeichenlose
Ganzzahl mit Wert `0` oder `1`.

* Die Corelib **MUSS** dedizierte Boolean-Lese-/Schreibfunktionen mit dieser Abbildung
  bereitstellen.
* Auf dem Draht ist das Ergebnis von einer vorzeichenlosen Ganzzahl nicht unterscheidbar.
  `boolean true` bei ID `0` → `00 01`.
* Die gemeinsamen Vektoren führen entsprechend eine `boolean`-Op.

Andere Schematypen, die auf eine vorzeichenlose Ganzzahl abbilden (Bitfelder, Flag-Sets),
sind Sache der Message-Schicht (MESSAGE_SPEC §1); die Corelib sieht immer nur eine plane
vorzeichenlose Ganzzahl.

### 4.5 Vorzeichenbehaftete Ganzzahl (Typ `0b001`)

```
[ header_varint ] [ zickzack(wert)_varint ]
```

Varint dekodieren, dann zick-zack-dekodieren. Schematypen, die auf eine vorzeichenbehaftete
Ganzzahl abbilden (Enums, einschließlich ihres 32-Bit-Bereichs), sind Sache der
Message-Schicht (MESSAGE_SPEC §1).

### 4.6 Fixlen-Wert (Typ `0b010`)

```
[ header_varint ] [ fixlen_word_varint ] [ nutzlast-bytes... ]

fixlen_word = (länge << 3) | fixlen_typ
```

Längenbereich `0 .. 2.147.483.647` (`FIXLEN_MAX`, §6.2). Subtypen:

| Bits | Wert | Subtyp | Nutzlast |
|---|---|---|---|
| `0b000` | 0x0 | IEEE-754 32-Bit-Float | exakt 4 Bytes, little-endian |
| `0b001` | 0x1 | IEEE-754 64-Bit-Double | exakt 8 Bytes, little-endian |
| `0b010` | 0x2 | UTF-8-String | rohes UTF-8, **kein** abschließendes NUL |
| `0b011` | 0x3 | BLOB | opake Bytes |
| `0b100`–`0b111` | 0x4–0x7 | **reserviert** | — |

Normative Regeln:

* **Falsche Float-Breite ist `INVALID`.** Ein `fixlen_word`, das für `fp32` / `fp64` eine
  andere Länge als 4 / 8 deklariert, ist fehlgeformt (§5.2), und ein Decoder **MUSS** es
  **beim Lesen des `fixlen_word`** zurückweisen — bevor er Nutzlast-Bytes konsumiert oder
  auf sie wartet (§5.2).
* **Reservierte Subtypen sind `INVALID`.** Ein Decoder **MUSS** `0x4`–`0x7` zurückweisen
  (§5.2).
* **Floats round-trippen bit-für-bit.** Nutzlasten sind rohe IEEE-754-little-endian-Bytes,
  also überleben `±0`, `±inf` und jedes `NaN` exakt. Die Corelib inspiziert oder
  normalisiert nie eine Float-Nutzlast. Ein **signalisierendes** `fp32`-NaN **DARF NICHT**
  gequietet werden — siehe §6.5, normativ für Sprachen, deren einziger Float-Typ ein
  Double ist.
* **Strings tragen keinen Terminator.** Aufrufer, die einen brauchen, hängen ihn selbst an.
* **Skip** konsumiert exakt `länge` Nutzlast-Bytes.

*Testhinweis:* JSON kann `NaN` nicht darstellen, die gemeinsamen Vektoren lassen es also
aus; Konformitätstests vergleichen Floats per **Bitmuster**, nie per `==` — denn
`NaN != NaN`.

### 4.7 Array vorzeichenloser / vorzeichenbehafteter Ganzzahlen (Typen `0b011` / `0b100`)

```
[ header_varint ] [ element_count_varint ] [ elem_0_varint ] [ elem_1_varint ] ...
```

* `element_count` im Bereich `0 .. 2.147.483.647` (`ARRAY_MAX`, §6.2). Der Zähler erlaubt
  einem Decoder, das Ziel zu validieren oder das Array Element für Element zu überspringen.
* **`element_count` darf `0` sein** — ein gültiges, vollständig spezifiziertes leeres Array,
  exakt `[ header ][ count = 0 ]`, ohne folgende Elemente und ohne `fixlen_word`
  (Integer-Arrays haben keines; ihre Elementbreite ist eine API-Frage, keine Wire-Frage).
* Jedes Element ist ein eigenständiges Varint (vorzeichenlos) bzw. Zick-Zack-Varint
  (vorzeichenbehaftet); die Byte-Länge pro Element variiert.
* Die auf der API deklarierte Elementbreite (8/16/32/64 Bit) beeinflusst nur, wie ein
  dekodierter Wert **gespeichert** wird — nie die Wire-Bytes.

Was ein explizit leeres Array gegenüber einem abwesenden Feld *bedeutet*, ist eine Frage der
Message-Schicht (MESSAGE_SPEC §2), keine Wire-Frage.

### 4.8 Array von Fixlen-Werten (Typ `0b101`)

```
[ header_varint ] [ element_count_varint ] [ fixlen_word_varint ] [ nutzlast... ]
```

* Ein **einziges** `fixlen_word` gibt Subtyp und **Pro-Element**-Byte-Länge an, gültig für
  alle Elemente.
* Nutzlast ist `element_count × element_länge` zusammenhängende Bytes.
* Nur Subtypen **fester Breite** sind erlaubt: `fp32`, `fp64`. **String und Blob sind in
  einem Fixlen-Array NICHT erlaubt** — ein Array von Strings modelliert man mit einer
  Sequence (§4.9).
* Elemente sind little-endian.
* **`element_count == 0` behält das `fixlen_word`**: Das Feld ist exakt
  `[ header ][ count = 0 ][ fixlen_word ]`. Ohne es wären ein leeres `fp32`-Array und ein
  leeres `fp64`-Array beide `[ header ][ count = 0 ]`, und ein Decoder, der den Subtyp vom
  Draht ableitet, könnte sie nicht unterscheiden.

#### 4.8.1 Decode-Reihenfolge: beide Wörter, dann Subtyp, dann Schema-Schranke (normativ)

Der `element_count` steht vor dem `fixlen_word`, ein Decoder erfährt also *wie viele*
Elemente, bevor er erfährt *von welchem Typ* — und diese beiden Antworten gehören
verschiedenen Autoritäten: Das **Format** beschränkt den Zähler, das **Schema** beschränkt
das Array. Ein Decoder geht daher so vor:

1. `element_count` lesen und dabei die Format-Obergrenze `ARRAY_MAX` (§6.2) durchsetzen —
   und auf die bloße Behauptung dieses Zählers hin keinen Speicher binden, bevor er geprüft
   ist (§6.2.1);
2. das `fixlen_word` lesen: Subtyp und Pro-Element-Länge;
3. **widerspricht** der Subtyp dem deklarierten Elementtyp, das Feld gemäß
   MESSAGE_SPEC §7.3 **überspringen** — `element_count × element_länge` Bytes — und das
   deklarierte Feld auf seinem Default lassen. Die Schema-`count` **DARF NICHT** angewendet
   werden: Das Feld war nie der Wert dieses Arrays, also ist sein Element-Zähler nicht
   dessen Zähler;
4. andernfalls die **Schema**-`count`-Schranke anwenden (MESSAGE_SPEC §7.1): Ein
   `element_count` über der deklarierten `count` ist `INVALID`.

Diese Reihenfolge kostet nichts: Ein Fixlen-Array ist ohne das `fixlen_word` gar nicht
überspringbar, denn die Nutzlast-Länge ist `element_count × element_länge`. Ein konformer
Decoder hat beide Wörter ohnehin gelesen, bevor er in irgendeiner Weise handeln kann.

Zwei Konsequenzen, beide **beabsichtigt**:

* Eine Nachricht, die **zwischen** den beiden Wörtern endet, ist `INCOMPLETE`, nicht
  `INVALID` — auch wenn der `element_count` die Schema-`count` bereits überschreitet: Der
  Decoder kann noch nicht wissen, ob dies das Feld ist, das er beschränken muss. (§5.2 gibt
  `INVALID` nur Bytes, die *unabhängig vom Folgenden* fehlgeformt sind; diese sind es
  nicht.)
* Die **Format**-Obergrenze feuert am Zähler-Wort, egal was der Subtyp am Ende ist.

### 4.9 Sequence-Start (`0b110`) und Sequence-Ende (`0b111`)

```
sequence-start:  [ header_varint = (id << 3) | 0b110 ]
   ... kind-felder, ggf. verschachtelte sequences ...
sequence-ende:   [ 0x07 ]      // (id = 0) << 3 | 0b111, ein einzelnes Byte
```

Die einzige Wirkung einer Sequence ist ein frischer ID-Scope (§3).

**Ein Sequence-Ende trägt in seiner ID keine Information (normativ).**

* Ein Encoder **MUSS** ein Sequence-Ende als exakt `0x07` ausgeben.
* Ein Decoder **MUSS** die ID **verwerfen**: Der Marker schließt die innerste offene
  Sequence, egal was die ID sagt, und re-enkodiert als `0x07`.
* Das ID-Teilfeld existiert nur, damit jeder Header ein `(id << 3) | typ`-Varint bleibt.

**Verworfen heißt nicht ungeprüft.** Die ID ist durch `ID_MAX` beschränkt wie die jedes
anderen Headers (§6.2): Eine ID über der Obergrenze ist `INVALID` (§5.2) — auf einem
Sequence-Ende wie überall. Die Schranke gilt dem **Wert** der ID, nicht ihrer Schreibweise —
§4.1.2 bleibt unberührt, eine nicht-minimale Kodierung einer gültigen ID (`0x87 0x00`, oder
eine ID von 3) wird akzeptiert, dekodiert und als `0x07` re-emittiert. Es gibt bewusst
**keine Ausnahme** für Wire-Typ 7: Eine Regel deckt jeden Header ab, ein Decoder validiert
die ID dort, wo er den Header liest, und verzweigt nie zuerst auf den Wire-Typ.

Weitere Regeln:

* **Eine Sequence überspringen** heißt, bis zu ihrem passenden Ende zu laufen — in
  verschachtelte Sequences absteigend, mit Tiefenzähler. Das Ende ist ein Marker, keine
  Länge.
* **Eine leere Sequence** (`start` direkt gefolgt von `0x07`) ist legal, ein Decoder
  **MUSS** sie akzeptieren. Sie ist das Komposit-Gegenstück des Null-Zähler-Arrays (§4.7).
  Was sie *bedeutet*, ist Sache der Message-Schicht (MESSAGE_SPEC §2, §4); §6s Framing-API
  ist, was einem Encoder die Entscheidung ohne Pufferung erlaubt.
* **`MAX_DEPTH` ist 255** (§6.2). Ein Encoder **DARF NICHT** mehr als 255 verschachtelte
  Sequences öffnen; ein Decoder **MUSS** tiefere Verschachtelung als `INVALID` zurückweisen,
  statt unbeschränkte Rekursion zu riskieren.

*Implementierungshinweis:* Das Dekodieren eines sequence-verpackten Arrays braucht keine
eigenen Zustände. Nach einem `sequence-start` ist der Decoder wieder in seinem
Idle-Zustand und liest gewöhnliche Feld-Header — Array-of-Composite nutzt Idle +
Sequence-Push/Pop + Blatt-Zustände wieder, und Überspringen läuft über denselben
Tiefenzähler. Nur die zähler-präfixierten Array-Typen (§4.7–4.8) brauchen zählergetriebene
Zustände.

### 4.10 Durchgerechnetes Beispiel

Nachricht `{ id=0: unsigned 127 }`:

```
00        header: id=0, typ=0b000 (unsigned)
7f        wert-varint = 127
```

→ `00 7f`, 2 Bytes. Das ist exakt Testvektor `unsigned_0x7F`.

---

## 5. Das Streaming-Modell (das Herz des Designs)

Jede Implementierung **MUSS** auf beiden Seiten streaming-fähig sein: Die Nachricht darf
größer sein als jeder Puffer, den das Programm hält, und darf inkrementell erzeugt oder
konsumiert werden.

### 5.1 Streaming-Serialisierung (Encoder)

Der Encoder schreibt in einen **Ausgabepuffer** und ruft eine **Flush-/Drain**-Operation
auf, wenn er voll wird (oder bei explizitem Flush). Der Flush reicht die angesammelten
Bytes weiter; der Encoder schreibt in den nun leeren Puffer weiter.

**Der Ausgabepuffer DARF beliebig kleiner sein als die Nachricht (normativ).** Was den
Speicher begrenzt, ist der Puffer — nicht die Nachricht.

#### 5.1.1 Erforderliche Fähigkeiten

* Einen **Aufrufer-Puffer** annehmen — Pointer/Slice, Länge, Start-Offset — **ohne**
  Flush-Sink. Der Offset lässt vorn Platz für einen Framing-Header; ein voller Puffer
  meldet buffer-full, statt überzulaufen.
* Denselben Puffer **mit** Flush-Callback annehmen, oder verbunden mit einem
  sprachidiomatischen Stream/Writer-Sink.
* Erlauben, **mitten im Stream einen neuen Ausgabepuffer zu installieren** (§5.1.5).
* Einen **expliziten Flush** anbieten, der verbliebene Bytes am Ende ausleert.
* Auf jeder Schreiboperation einen Status-/Fehlercode zurückgeben.

#### 5.1.2 Eine Corelib DARF NICHT

* **Einen Ausgabepuffer allokieren.** Jeder Puffer, in den der Encoder schreibt, kommt vom
  Aufrufer. Ein Puffer-Eigentumsmodell, nicht zwei; ein heap-loses Profil ist dessen
  einfache Lesart, kein Sonderfall. Das ist die Encode-Hälfte von **§6.6**.
* Einen Aufrufer-Puffer **vergrößern oder reallozieren**. Was übergeben wurde, wird
  beschrieben.
* **Teilausgabe als vollständig zurückgeben.** Ein Encoder, der nicht schreiben konnte, was
  verlangt war, meldet das — und ein One-Shot-Helfer, der diese Meldung ignoriert, ist
  nicht konform.

Der Speicher, den ein One-Shot-`encode()` zurückgibt, kommt aus der **generierten
Schicht**, die das Schema kennt (§6.6). Zwei Formen sind konform, und der Generator
emittiert beide:

| Schema | Form |
|---|---|
| **beschränkt** | `MAX_SIZE` allokieren (§6.1.1), **ohne** Sink installieren, in einem Durchlauf enkodieren. Der Worst-Case ist aus dem Schema abgeleitet und unüberschreitbar — kein Flush möglich, kein Minimum anwendbar. |
| **unbeschränkt** | `MAX_SIZE` ist dann eine konfigurierte Obergrenze, keine unerreichbare Größe — danach zu dimensionieren würde abschneiden. Stattdessen einen Scratch-Puffer **mit** Sink installieren, der in das wachsende Ergebnis anhängt; der Scratch unterliegt `MIN_OUTPUT_BUFFER` wie jeder Sink-installierte Puffer. |

Auf einem heap-losen Profil existiert nur die beschränkte Form — weshalb MESSAGE_SPEC §7.2
bereits verlangt, dass ein dafür gedachtes Schema seine Schranken deklariert.

#### 5.1.3 Wo eine Flush-Grenze liegen darf (normativ)

Die erzeugte Byte-Folge ist eine Verkettung **atomarer Einheiten** und **teilbarer Läufe**.

| Klasse | Mitglieder |
|---|---|
| **Atomar** | ein Feld-Header-Varint (§4.3); ein `fixlen_word` (§4.6); ein `element_count`-Varint (§4.7–4.8); das Varint eines Integer-Skalars oder eines Integer-Array-Elements (§4.4–4.5, §4.7); ein `fp32`/`fp64`-Element (§4.6, §4.8) |
| **Teilbar** | der Nutzlast-Byte-Lauf eines `string` oder `blob` (§4.6), an jeder Byte-Grenze |

* Eine Flush-Grenze **DARF** zwischen zwei atomaren Einheiten und überall innerhalb eines
  teilbaren Laufs liegen.
* Ein Encoder **MUSS** einen teilbaren Lauf über einen Flush hinweg aufteilen können — ein
  Feld ohne Schema-`maxlen` kann jeden Puffer überschreiten; kein Minimum beseitigt diesen
  Pfad.
* Ein Encoder **DARF** verlangen, dass jede atomare Einheit zusammenhängend landet.

Die Regel gilt über die **erzeugten Bytes**, nicht die Daten des Aufrufers: Ein Target,
dessen nativer String UTF-16 ist, emittiert einen Nutzlast-Lauf, der seine Eingabe nie war —
und geteilt wird von einem Flush der Lauf im Puffer.

#### 5.1.4 `MIN_OUTPUT_BUFFER` (normativ)

Eine Corelib **MUSS** eine dokumentierte Konstante bereitstellen — den kleinsten Puffer,
den sie **für Streaming** akzeptiert.

| Port-Verhalten | deklariert |
|---|---|
| teilt auch atomare Einheiten | **`1`** |
| verlangt atomare Einheiten zusammenhängend | den größten Lauf, den er als ein Stück reserviert; abgeleiteter Boden **10** (ein 64-Bit-Varint, `ceil(64/7)`) |
| reserviert Header samt Wert | diese Summe |

* Eine Deklaration **DARF NICHT** über **20** liegen — ein Header-Varint samt Wert,
  `2 × 10`. Das ist die größte Reservierung, die irgendein Port macht, und zugleich die
  kleinste Nachricht, die ein Schema beschränken kann — eine höhere Obergrenze ließe einen
  Port mehr verlangen, als eine ganze Nachricht belegen kann.
* Weiter vorauszureservieren — die Metadaten eines Feldes als Gruppe, ein Batch von
  Array-Elementen — **MUSS** über Flushen gelöst werden, nicht über eine Erhöhung der
  Deklaration.
* **Das Minimum bindet einen mit Flush-Sink installierten Puffer**, bei Installation und
  bei jedem Mid-Stream-Buffer-Set. Ein solcher Puffer **MUSS** `buflen - offset >=
  MIN_OUTPUT_BUFFER` erfüllen und wird **bei der Übergabe** zurückgewiesen — mit demselben
  Mechanismus wie ein Offset außerhalb des Bereichs, nie mitten in einer Nachricht.
* Jeder Puffer ab dem Minimum **MUSS** funktionieren und **MUSS** byte-identische Ausgabe
  zum One-Shot-Pfad erzeugen.
* **Ein ohne Sink installierter Puffer unterliegt keinem Minimum.** Kein Flush kann
  auftreten, keine atomare Einheit kann geteilt werden. Der Puffer hält die Nachricht oder
  meldet buffer-full. Das ist der Fall, den ein Aufrufer nach `MAX_SIZE` (§6.1.1)
  dimensioniert, und er bleibt exakt: Eine Zwei-Byte-Nachricht enkodiert auf jedem Port in
  einen Zwei-Byte-Puffer.

*Warum eine Konstante statt eines festen Bodens von 1:* Wer portablen Code schreibt, muss
die funktionierende Größe **erfragen** können, statt sie zur Laufzeit zu erfahren, wenn es
zu spät ist. Die Konstante aufs Streaming zu beschränken hält sie vom One-Shot-Pfad fern,
wo kein Flush auftreten kann.

**`1` zu deklarieren bleibt voll konform** und ist die richtige Wahl für ein
Footprint-Profil: Byte-genaues Enkodieren ist, wofür das Wire-Format entworfen wurde, und
auf einem Target, das durch einige Dutzend Bytes Scratch streamt, kostet es weniger als der
RAM eines größeren Puffers. Man beachte die Richtung — hier ist das **eingeschränkte**
Profil das strikte, und das Max-Speed-Profil nimmt die Erlaubnis: die Umkehrung der
Constrained-Profile-Erlaubnisse in §6.2. Anders als jene ändert dies nichts am Draht; nur
eine API-Vorbedingung unterscheidet sich.

#### 5.1.5 Puffer-Übergabe: was ein zurückkehrender Flush-Callback hinterlässt (normativ)

Ein Sink kann die übergebenen Bytes **kopieren** oder den Puffer **nehmen** (an einen
Transport reichen, einreihen, an DMA geben) — und der Encoder kann beides nicht
unterscheiden. Der Vertrag hängt daher an dem, was der Callback **vor seiner Rückkehr**
tut:

| der Callback kehrt zurück | bedeutet | der Encoder |
|---|---|---|
| **ohne** einen Puffer zu installieren | der Sink hat **kopiert** | schreibt im aktiven Puffer weiter, ab Offset **0** |
| **nachdem** er einen Ersatz installiert hat | der Sink hat den Puffer **genommen** | schreibt in den Ersatz |

Ein Sink, der den Puffer nimmt, **MUSS** vor der Rückkehr einen Ersatz installieren. Er
**DARF NICHT** ohne zurückkehren — der Encoder schriebe sonst in Speicher, der jetzt dem
Transport gehört.

**Der Start-Offset gehört zur Installation, nicht zum Puffer.** Jeder Buffer-Set-Aufruf
beginnt eine neue Installation, deren Cursor beim Offset *dieses Aufrufs* startet; der
Offset ist damit verbraucht — ein späterer Flush, aus dem der Callback ohne Installation
zurückkehrt, setzt bei 0 fort. Denselben Puffer erneut an Buffer-Set zu geben ist eine neue
Installation wie jede andere — so bekommt ein Sink in **jeder** geflushten Einheit frischen
Header-Platz, ein Framing-Header pro Paket.

*Warum herum:* Den **Ausgabepuffer** an einen Transport zu übergeben ist der Grund, warum
Buffer-Set existiert — direkt ins Paket enkodieren, das Paket weiterreichen, das nächste in
einen anderen Puffer. (Das ist eine encode-seitige Puffer-Übergabe und hat mit den in §6.7
verbotenen Views auf dekodierte Werte nichts zu tun: Der Puffer gehört dem Aufrufer, und
der Aufrufer ist es, der ihn weggibt.) Das ist nur sicher, wenn „ohne Installation
zurückgekehrt" genau eine Bedeutung hat. Sie als „Speicher wiederverwenden" zu lesen ist
der sichere Default für einen kopierenden Sink und das, was ein nehmender Sink
überschreiben muss; andersherum wäre der gefährliche Fall der implizite.

#### 5.1.6 Pass-Through eines teilbaren Laufs ist verboten (normativ)

**Ein Encoder DARF dem Sink keinen anderen Speicher übergeben als den installierten
Ausgabepuffer.** Jedes Byte, das ein Sink erhält, liegt im Puffer, den der Aufrufer
installiert hat — bei jedem Flush, ohne Ausnahme. Ein `string`- oder `blob`-Nutzlast-Lauf
wird durch den Ausgabepuffer kopiert wie alles andere, wie groß er auch ist und wo seine
Bytes auch schon liegen.

Eine frühere Fassung erlaubte einem Encoder, einen solchen Lauf direkt an den Sink zu
reichen und so eine Kopie zu sparen. Diese Erlaubnis ist zurückgezogen, aus zwei Gründen:

* **Es widerspricht dem, was ein Chunk ist.** Eine geflushte Einheit ist nicht bloß „ein
  paar Bytes" — sie kann ein Fragment eines darunterliegenden Protokolls sein, vom Aufrufer
  gerahmt, mit vorn reserviertem Platz (§5.1.1), als Einheit an einen Transport gereicht.
  Fremder Speicher mitten in dieser Folge ist kein solches Fragment: Er trägt keinen
  reservierten Header-Platz, er lässt sich nicht rahmen, und er lässt das Sink-Argument auf
  zwei aufeinanderfolgenden Aufrufen zwei Verschiedenes bedeuten.
* **Es kaufte eine Kopie zum Preis eines zweiten Vertrags.** Pass-Through brauchte ein
  Erlaubnis-Flag bei der Installation, eine Reihenfolge-Regel übers Ausleeren, eine
  Leih-Regel übers Behalten und einen wechselseitigen Ausschluss mit Buffer-Set — vier
  Regeln, jede mit einem Fehlermodus, der nur unter einem nehmenden Sink sichtbar wird.
  Diese Komplexität trüge die Corelib für immer, in jedem Port, damit eine Nutzlastform
  eine Kopie spart.

**Konsequenzen, die ein Port nicht missverstehen darf:**

* Das sagt nichts darüber, **wo eine Flush-Grenze liegen darf** (§5.1.3). Ein teilbarer
  Lauf darf weiterhin an jedem Byte über Flushes verteilt werden — er wird zuerst in den
  Puffer kopiert.
* Es beschränkt nicht den **Aufrufer**. Wer die Kopie vermeiden will, dimensioniert seinen
  Ausgabepuffer auf die Nutzlast und installiert ihn ohne Sink (§5.1.4).
* Der **Puffer-Übergabe**-Vertrag (§5.1.5) bleibt unberührt und ist jetzt der *einzige*
  Weg, auf dem ein Sink je beeinflusst, in welchen Speicher der Encoder schreibt.

Siehe §6 für die vollständige Liste der Schreiboperationen.

### 5.2 Streaming-Deserialisierung (Decoder)

Der Decoder verwendet ein **Push-Feed / Pull-Read**-Modell:

* **Push** — der Aufrufer füttert rohe Bytes in beliebig kleinen Chunks. Header oder
  Nutzlast dürfen über viele `feed`-Aufrufe verteilt sein; die Zustandsmaschine pausiert
  und setzt an **jeder** Byte-Grenze fort.
* **Ereignis** — sobald ein vollständiger Feld-Header `(id, typ)` geparst ist,
  benachrichtigt der Decoder den **Feld-Handler** — den Visitor, die einzige
  Decode-Oberfläche (§5.3.1).
* **Pull** — der Handler wählt pro Feld:
  * den Wert in ein typisiertes Ziel **lesen**;
  * mit einem Kind-Handler in eine verschachtelte Sequence **absteigen**, rekursiv;
  * **skip** — die restlichen Bytes des Feldes, oder die ganze Sub-Sequence, werden mit den
    eintreffenden Chunks automatisch konsumiert und verworfen.

Diese Teilung ermöglicht eingangsseitiges Streaming: Der Konsument hält nie die ganze
Nachricht und bindet Ausgabespeicher spät, pro Feld.

*Terminologie:* „Pull-Read" benennt, was **innerhalb des Visitor-Callbacks** geschieht —
der Handler zieht den Wert in sein eigenes Ziel. Es ist keine Pull-Parser-*Oberfläche*, die
§5.3.1 verbietet: Der Codec treibt weiterhin, und der Handler wird gerufen; nichts
außerhalb des Visitors iteriert die Nachricht.

#### 5.2.1 Decode-Ergebnis: drei Werte, kein Finalize-Schritt (normativ)

Eine Chunk-Grenze darf **überall** liegen, auch mitten im Feld. Jedes `feed` — und das
One-Shot-`decode`, das ein einzelnes `feed` der ganzen Eingabe ist — liefert genau eines
von drei Ergebnissen, das die **bis dahin** konsumierten Bytes beschreibt:

| Ergebnis | One-Shot-Alias | Bedeutung | können mehr Bytes es ändern? |
|---|---|---|---|
| **`COMPLETE`** | `OK` | die konsumierten Bytes enden **exakt** an einer Feldgrenze; eine gültige Nachricht *darf* hier enden | weitere gültige Felder dürfen sie verlängern |
| **`INCOMPLETE`** | `OK_BUT_INCOMPLETE` | die Bytes enden **innerhalb** eines Feldes; der Teil-Rest wird fürs nächste `feed` behalten | **ja** |
| **`INVALID`** | `ERROR` | die Bytes sind fehlgeformt, **egal was folgt** (§5.2.2) | nein — terminal |

**`INCOMPLETE` ist KEIN Fehler.** Es ist ein vollwertiges Ergebnis, gleich zurückgegeben
von One-Shot-`decode` und Streaming-`feed`. Ein konformer Decoder **MUSS** es
unterscheidbar melden und **DARF** es in keinen Nachbarn falten:

* Falten in `COMPLETE` (einen abgeschnittenen Rest als fertig behandeln) ist nicht konform;
* Falten in `INVALID` (einen bloß über Chunks verteilten Strom zurückweisen, oder einen
  Präfix, den der Aufrufer noch verlängern kann) ist nicht konform.

#### 5.2.2 Was Bytes `INVALID` macht (normativ, die einzige Liste)

Diese Liste wird von überall sonst referenziert und nirgends wiederholt.

| Bedingung | Kapitel |
|---|---|
| ein Varint länger als 10 Bytes, oder mit Nutzbits auf Position ≥ 64 | §4.1.3 |
| eine **ID**, Länge oder ein Zähler über seiner Format-Obergrenze | §6.2 |
| ein reservierter Fixlen-Subtyp `0x4`–`0x7` | §4.6 |
| ein `fp32`/`fp64`-Fixlen, dessen deklarierte Länge nicht exakt 4 / 8 ist | §4.6 |
| Verschachtelung über `MAX_DEPTH` hinaus | §4.9 |
| ein Sequence-Ende-Marker ohne offene Sequence | §4.9 |
| ein Element-Zähler über der deklarierten Schema-`count` | MESSAGE_SPEC §7.1 |
| eine ungültige-UTF-8-`string`-Nutzlast, **die gelesen wird**, bei aktivierter Strict-Prüfung | §6.4 |

Zwei Dinge stehen bewusst **nicht** auf dieser Liste: ein **nicht-minimales Varint**
(§4.1.2, wird wegnormalisiert) und eine **Receiver-Cap-Zurückweisung** (§6.2.1, eine eigene
Policy-Kategorie).

#### 5.2.3 Vorrang: `INVALID` gewinnt über `INCOMPLETE` (normativ)

Enthalten die bis dahin konsumierten Bytes eine §5.2.2-Bedingung, ist das Ergebnis
**`INVALID`** — auch wenn die Eingabe *zusätzlich* abgeschnitten ist. `INCOMPLETE` wird
**nur** gemeldet, wenn jedes bisher konsumierte Konstrukt wohlgeformt ist und die Bytes
schlicht vor der Nachricht enden.

Ein Decoder **DARF** für Eingabe, die er bereits als fehlgeformt erkannt hat, **NICHT**
`INCOMPLETE` melden — keine Fortsetzung kann sie gültig machen, `INCOMPLETE` lüde den
Aufrufer also fälschlich ein, mehr zu füttern. Das kollidiert nicht mit der
Anti-Falt-Regel aus §5.2.1: Ein wohlgeformter, bloß abgeschnittener Präfix bleibt
`INCOMPLETE`.

**Folglich MUSS ein Decoder ein Konstrukt dort validieren, wo dessen beschreibende Bytes
gelesen werden** — Feld-Header, `fixlen_word` oder Zähler — bevor er die von ihnen
beschriebene Nutzlast konsumiert, puffert oder erwartet. Ein Decoder, der bis zum Eintreffen
der Nutzlast wartet, kann vorher das Eingabe-Ende erreichen und fehlgeformte Eingabe als
`INCOMPLETE` fehlmelden.

> Beispiel: `56 0a 59` — ein verschachteltes `fp64`, dessen `fixlen_word` Länge 11 ≠ 8
> deklariert, dann Abbruch. Das `fixlen_word` allein beweist die Nachricht fehlgeformt:
> `INVALID`, nicht `INCOMPLETE`.

**Zwei Ausnahmen**, jede dort formuliert, wo sie hingehört, und keine schwächt diese Regel:

* ein **unfertiges Varint** trägt gar kein Urteil (§4.1.1) — es ist kein Konstrukt, das der
  Decoder gelesen hat;
* **UTF-8-Ungültigkeit** wird bei Nutzlast-Abschluss gemeldet, nicht vorgezogen (§6.4),
  weil diese Prüfung keine Eigenschaft des Drahts ist.

#### 5.2.4 Kein Finalisieren — das Eingabe-Ende gehört dem Aufrufer (normativ)

Die drei Ergebnisse sind eine Eigenschaft der bis dahin konsumierten Bytes und an **jeder**
Byte-Grenze aus dem Decoder-Zustand berechenbar. Ein Decoder braucht daher **keinen**
`finish`/`finalize`/`end`-Schritt und **DARF** keinen anbieten, der `INCOMPLETE` zu
`INVALID` umklassifiziert. Der Status, den `feed`/`decode` liefert, *ist* die Antwort.

Ob `INCOMPLETE` akzeptabel ist, entscheidet der **Aufrufer** — nur er kennt sein Framing:

| Aufrufer | liest `INCOMPLETE` als |
|---|---|
| Streaming | „füttere mir den nächsten Chunk" |
| äußerer Rahmen (Längenpräfix, Datagramm, EOF), der alles geliefert hat | die Nachricht wurde **abgeschnitten** — ein Fehler auf *seiner* Schicht |
| One-Shot, der eine ganze Nachricht verlangt | Fehlschlag; er akzeptiert nur `COMPLETE` |

**Die Framing-Invariante**, rein über den zurückgegebenen Status ausgedrückt:

* eine gültige, ganze Nachricht wird **exakt** konsumiert → `COMPLETE`, nichts offen;
* Abschneidung (Bytes vor einem vollständigen Feld zu Ende) → `INCOMPLETE`;
* Rest-Bytes, die ein weiteres Feld *beginnen*, aber nicht beenden → `INCOMPLETE`;
* Rest-Bytes, die kein gültiges Feld beginnen können → `INVALID`;
* ein einzeln gefüttertes, hängendes `0x80` → **`INCOMPLETE`**: ein wohlgeformter
  Varint-Präfix (§4.1.1), den weitere Bytes vervollständigen könnten. Der Decoder
  entscheidet nie für den Aufrufer, dass ein Präfix „abgeschnitten" ist.

Generierter Code reicht diesen Status wörtlich durch (MESSAGE_SPEC §7).

### 5.3 Sprachidiomatische Muster

Eine neue Implementierung **SOLLTE** das beste idiomatische Muster ihrer Sprache verwenden,
solange Wire-Bytes und Streaming-Garantien erhalten bleiben.

#### 5.3.1 Der Visitor ist die einzige Decode-Oberfläche (normativ)

**Eine Corelib bietet genau eine Decode-Oberfläche: den Visitor.** Der Decoder ruft
typisierte Visitor-Methoden auf einem Objekt des Aufrufers; Pull-Read wird zu „der Visitor
schreibt den dekodierten Wert in eines der eigenen Member des Objekts und überspringt, was
er nicht erkennt".

* Jeder Port **MUSS** sie anbieten. In einer Sprache ohne Objekte sind das **Callbacks mit
  Kontext-Pointer** — dieselbe Form ohne den Typ. So erfüllt C die Regel; das ist keine
  Ausnahme.
* Ein Port **DARF** keine zweite Decode-Oberfläche anbieten: keinen Pull-Parser, keine
  Iterator- oder `next()`-artige API, keinen Cursor, keinen Convenience-Wrapper, der auf
  anderem Weg dekodiert. Das gilt auch für eingeschränkte Targets; es gibt keine
  Embedded-Ausnahme.

*Warum eine Oberfläche, und warum diese:*

* Der Hauptkonsument ist **generierter Code** — Objekte, deren Member die Schemafelder
  spiegeln und zur Decode-Zeit bereits existieren. Direkt in ein Member zu schreiben, das
  dem Aufrufer gehört, braucht keinen eigenen Speicher — das ist es, was den heap-freien
  Codec aus §6.6 überhaupt erreichbar macht. Eine Oberfläche, die materialisierte Werte
  zurückgibt, muss sie irgendwo bauen.
* **Jede zusätzliche Oberfläche ist eine zweite Implementierung jeder Regel dieses
  Dokuments.** §6.5 benennt den wiederkehrenden Defekt bereits: ein Schutz, der auf einer
  Oberfläche ergänzt wurde und auf der anderen fehlt. Dieselbe Divergenz trat bei
  Chunk-Behandlung, UTF-8-Validierung und Skip-Verhalten auf — und war jedes Mal für die
  gemeinsamen Vektoren unsichtbar, die genau die Oberfläche prüfen, die der Treiber
  zufällig wählte.
* Ein Port mit einer Oberfläche hat einen Ort, an dem er korrekt sein muss.

#### 5.3.2 Andere Muster, wo sie noch gelten

Diese betreffen den **Encoder** und den Build, nicht die Decode-Oberfläche:

* **Flush-Callback / Writer-Sink** — den Flush als Closure oder Stream/Writer-Sink
  modellieren, was die Sprache bevorzugt (§5.1).
* **Heap-freier Build** — für den Codec überall gefordert (§6.6); auf Targets, die weiter
  gehen können, auf die ganze Library ausdehnen.
* **Feature-Flags / Build-Optionen** — Fixlen-, fp64-, Array- oder Sequence-Unterstützung
  und Integer-Überlauf-Prüfungen abschaltbar machen, um den Footprint zu verkleinern.
* **Bereitschaft zur nativen Beschleunigung** für Skriptsprachen — eine
  Pure-Language-Implementierung ist ein gültiger Anfang, aber die Hot-Path-Primitive
  (Varint-Encode/Decode, Puffer-Operationen, Header-Parsing) hinter internen Helfern
  isolieren, damit sie später **ohne Änderung der öffentlichen API** durch eine native
  Extension ersetzbar sind: gleiche Namen, gleiche Argumentformen, gleiche Rückgabetypen.

Die **öffentliche API-Oberfläche und Benennung über die Sprachen hinweg vernünftig parallel
halten** (encode/decode, sequence begin/end, read/skip), damit Nutzer beim Sprachwechsel
orientiert bleiben.

---

## 6. Sprachunabhängiger API-Vertrag

Eine konforme `corelib-<lang>` stellt mindestens die folgenden Fähigkeiten bereit.
**Namen** an die Konventionen der Sprache anpassen; **Semantik ist fest**.

**Namespace und Paketname (normativ)**

| | Wert | Hinweis |
|---|---|---|
| Namespace / Modul / Crate / Präfix | **`sofab`** | fest. Nicht `SofaB`, nicht `Sofab`, nicht `sofabuffers`. |
| Paketname in der Registry (crates.io, PyPI, npm, Maven Central, …) | **`SofaBuffers`** | was Nutzer in ihr Manifest tippen (`Cargo.toml`, `pyproject.toml`, `package.json`, …) |

Die beiden unterscheiden sich mit Absicht: Nutzer installieren `SofaBuffers` und
importieren `sofab`.

**API-Version.** Eine Konstante oder einen Getter bereitstellen, der die ganzzahlige
API-Version liefert, derzeit **`1`** (§6.2). Aufrufer und Generator prüfen damit die
Kompatibilität.

### 6.0 Operationen

**Encoder**

* Initialisierung mit einem Ausgabe-Sink — Puffer + Flush, oder Stream/Writer (§5.1).
* **Schreiboperationen** für jeden Skalartyp: unsigned, signed, boolean, fp32, fp64
  *(optional/feature-gated)*, string, blob. Boolean bildet auf unsigned `0`/`1` ab (§4.4).
  Mit Überladung ein `write(id, wert)`, das nach Typ dispatcht; sonst
  `write_<typ>(id, wert)`.
* **Array-Schreiben** für Unsigned-Integer-, Signed-Integer- und Fixlen-(fp32/fp64-)Arrays.
* **Sequence-Framing** — Scopes öffnen und schließen, in einer Form, die der
  Message-Schicht erlaubt, eine All-Default-Sequence **ohne Pufferung der Nachricht**
  wegzulassen (§6.0.1).
* `flush()`, und die Möglichkeit, mitten im Stream einen neuen Ausgabepuffer einzusetzen
  (§5.1.5).

**Decoder**

* Initialisierung mit einem Feld-Handler: dem **Visitor** (§5.3.1) — und keiner anderen
  Oberfläche.
* `feed(bytes)`, das beliebig kleine Chunks akzeptiert und `COMPLETE` / `INCOMPLETE` /
  `INVALID` liefert (§5.2). **Kein** `finish`/`finalize`-Schritt.
* Pro Feld **read** in ein typisiertes Ziel oder **skip** — genau diese zwei Absichten, nie
  eine dritte (§6.7.2). Mit Überladung genügt ein `read(ziel)`; sonst `read_<typ>(ziel)`.
* **Abstieg** in verschachtelte Sequences mit einem Kind-Handler (z. B. `read_sequence`),
  mit Auto-Skip ungelesener Felder und ganzer Sub-Sequences.

**Chunk-Lebensdauer (normativ).** Ein gefütterter Chunk ist **nur für die Dauer des
`feed`-Aufrufs** geliehen. Sobald `feed` zurückkehrt, darf der Aufrufer diesen Speicher
wiederverwenden, überschreiben oder freigeben, und die dekodierte Nachricht **DARF NICHT**
betroffen sein. Ein Decoder kopiert also aus einem Chunk heraus, bevor er zurückkehrt — wie
er es für eine über Chunks verteilte Nutzlast ohnehin muss, die keinen einzelnen Chunk hat,
auf den sie zeigen könnte.

**Es gibt keine Ausnahme für den One-Shot-Pfad.** `decode(buffer)` kopiert exakt wie
`feed` — obwohl der Aufrufer diesen Puffer nachweislich am Leben hält —, sonst hinge das
Speicherverhalten eines Ports davon ab, welcher Einstiegspunkt benutzt wurde (§6.7.1).

*Warum:* Ohne diese Regel hinge die Pflicht des Aufrufers davon ab, wo die Chunk-Grenzen
zufällig lagen — eine in einem Chunk eintreffende Nutzlast geliehen, dieselbe über zwei
verteilt kopiert. *Dieselbe Nachricht über ein anderes Chunking* stellte also verschiedene
Anforderungen an denselben aufrufenden Code. §6.4 und §7.2 Punkt 4 verbieten diese Klasse
von Variation bereits fürs Decode-Ergebnis; Speicherpflichten bekommen dieselbe Antwort.

#### 6.0.1 Sequence-Framing: `begin_lazy` / `end` / `end_keep` (normatives Ergebnis)

MESSAGE_SPEC §2 lässt ein sequence-typisiertes **Feld** weg, dessen Wert seinem
deklarierten Default entspricht, und behält den Rahmen eines Wrapper-Array-**Elements**,
das ganz auf Default steht. Beides entscheidet sich daran, *was die Kinder am Ende sind* —
während der Sequence-Header **vor** ihnen auf den Draht muss. Ein naiver Encoder müsste die
Sub-Nachricht puffern, um es zu erfahren. Er muss nicht.

**Die Pflicht der Corelib ist das Ergebnis.** Die Form unten erfüllt es in einem einzigen
Vorwärtslauf:

| Operation | Wirkung |
|---|---|
| `sequence_begin_lazy(id)` | öffnet einen Scope und **hält den Header zurück**. Die IDs der innersten offenen Sequences bilden einen schwebenden Lauf. |
| jedes Feld-Schreiben | emittiert zuerst den ganzen schwebenden Lauf, äußerster Header zuerst, dann das Feld. Inhalt zu schreiben ist, was jede umschließende Sequence als nicht-default beweist. |
| `sequence_end()` | wird der Header dieser Sequence noch zurückgehalten, bekam sie keinen Inhalt: **fallen lassen**, Header und Ende-Marker beide. Sonst `0x07` emittieren. |
| `sequence_end_keep()` | verhält sich wie ein Schreiben: den schwebenden Lauf *und* den Ende-Marker emittieren — eine Sequence ohne Inhalt erreicht den Draht trotzdem als `begin` + `end`. |

Die Wahl zwischen den beiden Schließern ist **statisch** — eine Eigenschaft der Position im
Schema, generierter Code entscheidet sie zur Generierungszeit:

| Position | Schließer |
|---|---|
| `struct`- / `union`-Feld | `end` |
| Array-Feld (der Wrapper) | `end` |
| Wrapper-Array-**Element** (`struct`/`union`/verschachtelte Zeile) | `end_keep` |
| Array-Feld, das bereits als abweichend von einem **nicht-leeren** deklarierten `default` bekannt ist | `end_keep` |

**`end_keep` ist der sichere Default**, denn die Fehlerrichtungen sind nicht symmetrisch:
Es zu verwenden, wo `end` genügte, kostet einen nicht-kanonischen leeren Rahmen, den ein
Decoder wegnormalisiert (MESSAGE_SPEC §2) — die Umkehrung lässt ein Element fallen und
ändert stillschweigend die **Länge** eines Arrays.

**Einen Header zurückzuhalten ändert die Bytes nie.** Schwebende IDs sind Encoder-Zustand,
kein Pufferinhalt — ein Flush kann keinen schwebenden Lauf teilen, und ein Ausgabepuffer
kleiner als die Nachricht erzeugt exakt die One-Shot-Bytes (§5.1, §7.2).

**Das ist eine empfohlene Form, keine vorgeschriebene API.** Was jede Implementierung
**MUSS**, ist die kanonische Kodierung von MESSAGE_SPEC §2 erzeugen.

* Eine Implementierung, deren Message-Schicht eine **Deskriptor-/Objekttabelle** ist, kann
  jedes Feld *vor* dem Öffnen gegen seinen Default prüfen (wie die C-Referenz in
  `sofab_object_encode`) und erfüllt die Pflicht mit dem einfachen eifrigen
  `sequence_begin` / `sequence_end`-Paar.
* Das Zurückhalte-Trio existiert für den anderen Fall: Ist die Message-Schicht
  **generierter Code**, verteilt sich das Prädikat über Dutzende einzelner
  Schreibaufrufe — und der Ausgabestrom ist der einzige Ort, der sie alle sieht.
* Ein Profil, das das Trio nur für generierte Konsumenten anbietet, **DARF** es zur
  Build-Option machen (die C-Referenz schaltet es hinter
  `SOFAB_DISABLE_LAZY_SEQ_SUPPORT`). Ein solcher Schalter ändert das Kontext-Layout und
  **MUSS** für die Library und alles, was sie einbindet, identisch konfiguriert sein.

**Wie tief das Zurückhalten reicht (normativ).** Der schwebende Lauf wächst mit der
Verschachtelung.

* Der schwebende Lauf ist **Zustand fester Größe** (§6.6.2): höchstens `MAX_DEPTH` IDs, bei
  der Konstruktion dimensioniert. Eine Implementierung **MUSS** bis zur vollen `MAX_DEPTH`
  (§6.2) zurückhalten und ist damit auf jeder Tiefe kanonisch.
* Ein **eingeschränktes Profil DARF** den Lauf auf eine kleinere feste Tiefe begrenzen und
  jenseits davon eifrig rahmen — es emittiert den leeren Rahmen, den §2 weggelassen hätte.
  Diese Ausgabe ist **wohlgeformt und dekodiert zum selben Wert** — es ist die
  nicht-kanonische Form, die jeder Decoder ohnehin akzeptiert und normalisiert —, die
  beiden Profile interoperieren also. Was sie nicht ist, ist kanonisch.
* Ein Profil, das diese Erlaubnis nimmt, **MUSS die Schranke dokumentieren**: Zwei Encoder,
  die über sie uneins sind, sind über **Bytes** uneins, nicht über Gültigkeit.

Das ist dieselbe Constrained-Profile-Erlaubnis wie in §6.2, aus demselben Grund: Eine
Schranke, die RAM pro Stream kostet, ist auf einem Target, das keinen übrig hat, ein echter
Preis.

### 6.1 Zwei Zielgruppen: direkte Corelib-Nutzung vs. generierte Objekte

Eine Corelib hat **zwei** Arten von Nutzern, und die API muss beiden dienen:

1. **Direkte Nutzung (Power-User).** Ein Entwickler ruft den rohen Encoder/Decoder von
   Hand, wählt Feld-IDs und Lese-/Schreibaufrufe selbst. Voll unterstützt — und die
   richtige Wahl für winzige Embedded-Nachrichten oder einmalige Wire-Arbeit.
2. **Generierte Objekte (der Normalweg).** Der **`generator`** macht aus einem Schema
   fertige Objekte/Klassen/Structs der Zielsprache; der Entwickler berührt die rohe API
   nie.

> **Architektur-Hinweis:** Die Corelib so entwerfen, dass eine *dünne* generierte Schicht
> obenauf sitzen kann. Die generierten Objekte sind das Produkt, mit dem die meisten
> Menschen umgehen — **ihre API muss extrem einfach sein** —, während die Corelib darunter
> genug Haken bietet, dass dieselben Objekte **in Chunks** serialisiert und deserialisiert
> werden können.

**Generierte Objekte müssen kinderleicht sein.** Wer ein generiertes `Person` benutzt,
denkt in Feldern, encode und decode — nie in Varints, Feld-IDs, Sequence-Markern oder
Puffern:

```
person = Person()           # einfache typisierte Felder: person.name, person.age, person.tags[]
person.name = "Ada"
person.age  = 36

bytes   = person.encode()               # One-Shot-Komfort
person2 = Person.decode(bytes)          # One-Shot-Komfort
```

* Generierte Felder sind gewöhnliche typisierte Member; IDs, Typen und Reihenfolge kommen
  aus dem Schema und bleiben verborgen.
* Verschachtelte Schema-Nachrichten werden verschachtelte generierte Objekte; wiederholte
  Felder werden der natürliche Listen-/Array-Typ der Sprache.
* Einzeilige `encode()` / `decode()` decken die 90 % ab.

**Aber generierte Objekte müssen AUCH streamen.** Die Komfortmethoden sind Abkürzungen;
jedes generierte Objekt akzeptiert zusätzlich einen inkrementellen Pfad:

```
# streaming HINAUS: einen bestehenden OStream/Sink füttern; Bytes gehen, wenn der Puffer voll wird
person.serialize(ostream)

# streaming HINEIN: einen Decoder mit beliebig kleinen Chunks füttern
dec = Person.decoder()
st = dec.feed(chunk1); st = dec.feed(chunk2); ...   # COMPLETE / INCOMPLETE / INVALID
person = dec.value                                   # inkrementell zusammengesetzt
# Kein finish()/end(): `st` ist das Ergebnis bis hierher (§5.2.4).
```

**Das drückt Anforderungen zurück in die Corelib.** Sie **MUSS**:

* dem Generator erlauben, das Enkodieren über denselben **Flush-Callback / Sink +
  Buffer-Swap**-Mechanismus zu treiben (§5.1), sodass `serialize` mit einem Puffer kleiner
  als das Objekt funktioniert;
* dem Generator erlauben, das Dekodieren über den **Push-Feed + Pull-Read / Visitor**-
  Mechanismus zu treiben (§5.2), sodass ein generierter Decoder beliebig kleine Chunks
  konsumiert, jedes Feld direkt in das Objekt-Member bindet, per `read_sequence` in
  verschachtelte Objekte absteigt und ein halbfertiges Objekt über Chunk-Grenzen hinweg
  fortsetzt.

#### 6.1.1 Kanonische Namen der Generated-Object-Schicht (normativ)

Generierte Typen landen im Namensraum des **Nutzers**, und jede zusätzliche Schreibweise,
die ein Port erfindet — `serialize_to`, `to_bytes`, `from_bytes`, `decode_from`,
`decode_into`, `marshal`, `unmarshal` — ist ein Name mehr, den ein Entwickler pro Sprache
für eine überall identische Operation lernen muss. **Die Menge ist geschlossen.** Nur
Groß-/Kleinschreibung und Idiom anpassen (`try_decode` / `tryDecode` / `TryDecode`), nie
die Wörter.

| Name | Art | Zweck |
|---|---|---|
| `encode()` | Instanz | One-Shot: die vollständige Nachricht als Bytes erzeugen |
| `decode(bytes)` | statisch / frei | One-Shot: das Objekt aus einer vollständigen Nachricht bauen; scheitert auf die sprachtypische Art |
| `try_decode(bytes)` | statisch / frei | die fehlbare Form für Sprachen, die Results zurückgeben statt zu werfen; liefert das Objekt oder den §6.3-Fehler |
| `serialize(ostream)` | Instanz | Streaming hinaus: die Felder des Objekts in einen Corelib-Ausgabestrom schreiben (§5.1) |
| `deserialize(istream, …)` | Instanz | Streaming hinein: der Pro-Feld-Haken, den der Decoder ruft (§5.2) |
| `decoder()` | statisch / frei | Streaming hinein: den generierten Reader holen, der Chunks `feed`et |
| `MAX_SIZE` | Konstante | die Worst-Case-Kodiergröße des Schemas; Verwendung siehe §5.1.2 |

* `encode` / `decode` sind die **Komfort**-Schicht; `serialize` / `deserialize` das
  **Streaming**-Paar — und das Komfort-Paar ein dünner Wrapper darüber.
* Ein Port **DARF** für keines von beiden einen zweiten Namen ergänzen — kein
  `serialize_to` neben `serialize`, kein `from_bytes` neben `decode`.
* Sprachlich verlangte Extras bleiben erlaubt, wo das Ökosystem sie fordert (ein
  `Display`/`ToString`, eine serde- oder `IXmlSerializable`-Brücke, ein idiomatischer
  Konstruktor); sie sind keine alternativen Einstiege ins Wire-Format.
* Alles unterhalb dieser Schicht — `feed`, `read_*`, `write_*`, `sequence_*` — ist
  Corelib-API (§6) mit eigenen Namen und nicht Teil der Oberfläche des generierten Objekts.

### 6.2 Limits & Konstanten (normativ)

| Konstante | Wert |
|---|---|
| `API_VERSION` | `1` |
| `ID_MAX` / Feld-ID-Bereich | `0 .. 2.147.483.647` (2³¹ − 1) |
| Unsigned-Wertebereich | 64 Bit vorzeichenlos (`0 .. 2⁶⁴ − 1`) |
| Signed-Wertebereich | 64 Bit vorzeichenbehaftet (`−2⁶³ .. 2⁶³ − 1`) |
| Skalar-Wertbreite | 64 Bit per Default |
| `FIXLEN_MAX` | bis 2.147.483.647 — **darf auf eingeschränkten Profilen 65.535 sein** |
| `ARRAY_MAX` | bis 2.147.483.647 — **darf auf eingeschränkten Profilen 65.535 sein** |
| `MAX_DEPTH` | 255 (maximale Sequence-Verschachtelungstiefe) |

Das sind **formatweite Obergrenzen**: Eigenschaften des Wire-Formats, für jede
Implementierung identisch — eine zu überschreiten ist `INVALID` (§5.2.2). Sie sind **kein**
Schutzmechanismus gegen einen feindlichen Sender — das ist §6.2.1.

**Die Constrained-Profile-Erlaubnis.** Wo die Tabelle *darf 65.535 sein* sagt, darf ein für
eingeschränkte Targets gebautes Profil die Obergrenze senken, weil die volle RAM pro Stream
kostet. Dieselbe Erlaubnis erscheint in §6.0.1 (Zurückhalte-Tiefe) und §6.4
(`SOFAB_STRICT_UTF8`). Ein Profil, das sie nimmt, **MUSS dokumentieren, was es gewählt
hat**; zwei Implementierungen, die über eine solche Schranke uneins sind, sind über
**Bytes** uneins, nicht über Gültigkeit. (§5.1.4 läuft andersherum — dort ist das
eingeschränkte Profil das strikte.)

**`ID_MAX` bindet jeden Header ohne Ausnahme** — die werttragenden Typen, Sequence-*Start*
und den **Sequence-Ende**-Marker gleichermaßen. Dass die ID eines Sequence-Endes verworfen
wird (§4.9), befreit sie nicht. Die Obergrenze ist über Header formuliert, nicht über
Header, deren ID ein Decoder zufällig konsultiert — das erlaubt, die ID dort zu validieren,
wo der Header dekodiert wird: ein unbedingter Vergleich, statt eine
Pro-Wire-Typ-Ausnahme durch jede Decode-Oberfläche zu tragen.

#### 6.2.1 Empfängerseitige technische Limits (normativ)

Ein Feld, dessen Schema keine Schranke deklariert (`maxlen`/`count` weggelassen —
MESSAGE_SPEC §7.2), ist **unbeschränkt**: Die *Nachricht* deklariert dafür keine
Obergrenze. Das ließe den **Sender** über die Allokation des **Empfängers** bestimmen —
also **MUSS** jeder Empfänger generische Maximallimits tragen:

| Limit | begrenzt |
|---|---|
| `max_dyn_array_count` | Elemente eines schema-unbeschränkten Arrays |
| `max_dyn_string_len` | Bytes eines schema-unbeschränkten `string` |
| `max_dyn_blob_len` | Bytes eines schema-unbeschränkten `blob` |

**Es gibt keinen Unset-Zustand und keinen Unlimited-Modus.** Vom Schema unbeschränkt heißt
immer noch: vom Empfänger beschränkt.

**Die Zahlen und die Allokation gehören nicht dem Codec.** Die Limits kommen aus
generiertem Code, der Schema und Target kennt. Die *Werte* sind ein Urteil pro Sprache und
Einsatz — eine Elementzahl, die auf einem Server trivial ist, ist in C brutal — und wie
viel allokiert wird, sobald ein Zähler sein Limit passiert hat, gehört ebenfalls der
generierten Schicht (§6.6). Dieses Kapitel legt nur fest, **wo die Prüfung stattfindet**
und **wie ihr Scheitern heißt**; SofaBuffers ARCHITECTURE §9.5 besitzt den Rest.

**Was der Codec beiträgt**, sind Meldung und Kategorie:

* Er meldet den **Zähler** am Zähler-/Längen-Header;
* für ein **Sequence-Array** meldet er den **Index** des vorliegenden Elements — die Länge
  eines Wrapper-Arrays ist *höchste vorhandene ID + 1* (MESSAGE_SPEC §5.1), der Index ist
  also das, was geprüft werden muss, denn einen Zähler-Header gibt es nicht;
* der Visitor entscheidet. Der Codec erfindet nie ein eigenes Limit und clampt nie auf
  eines.

**Diese Limits sind Konfiguration, nicht Schema:**

* gewählt vom **Implementierer/Deployment** zum Schutz des Systems, unabhängig von jeder
  Nachrichtendefinition, und **nicht** Teil des Wire-Vertrags;
* eines zu überschreiten ist eine **Policy-Zurückweisung — eine von `INVALID` getrennte
  Kategorie**. Die Bytes sind wohlgeformt und dekodieren unter einem lockereren Limit. Eine
  Implementierung **DARF** das **NICHT** als `InvalidMessage` melden und **NICHT** in das
  `INVALID`-Ergebnis falten (§6.3);
* sie **DÜRFEN NICHT** auf ein Feld angewendet werden, das das Schema bereits beschränkt.
  Dort regiert die Schema-Schranke, und ihre Verletzung ist `INVALID` (MESSAGE_SPEC §7,
  §7.1) — eine Schema-Schranke ist eine Aussage über *Gültigkeit*, ein Receiver-Limit über
  *Kapazität*;
* dass zwei verschieden konfigurierte Empfänger auf derselben Nachricht verschieden
  entscheiden, ist **kein** Interop-Fehler und **kein** Konformitätsdefekt.
  Konformitätstests vergleichen daher Implementierungen mit **identischen** Limits.

**Durchsetzungspunkt (normativ).** Ein Limit **MUSS** am Zähler-/Längen-Header durchgesetzt
werden — vor der Allokation, die es verhindern soll —, aus demselben Grund, aus dem
`INVALID` dort entschieden wird (§5.2.3). Für ein Sequence-Array, dessen Länge nicht
angekündigt wird, ist dieser Punkt der Element-**Index**, geprüft bevor der Container, in
den er zeigt, erweitert wird.

**Zurückgewiesen, nie geclampt.** Stillschweigend `limit` Elemente zu materialisieren, wo
der Draht mehr sagte, ist Datenkorruption in Warnweste.

*(Das ist das Empfänger-Kapazitäts-Gegenstück zu `MAX_DEPTH`: Beide begrenzen, was ein
Empfänger auf nicht vertrauenswürdige Eingabe hin bindet. `MAX_DEPTH` ist eine feste
Format-Obergrenze, ihre Verletzung fehlgeformte Eingabe; ein `max_dyn_*`-Limit ist
deployment-konfigurierbar, seine Verletzung nicht.)*

### 6.3 Fehlerbehandlung (normativ)

Jede fehlbare Operation meldet einen der Codes unten. Die Namen sind kanonisch;
Schreibweise und Idiom anpassen, Bedeutungen behalten. (Die C/C++-Referenz stellt sie als
`sofab_ret_t` / das `Error`-Enum bereit.)

| Code | Bedeutung |
|---|---|
| `None` / `OK` | Erfolg. |
| `BufferFull` | Ausgabepuffer beim Enkodieren übergelaufen. |
| `InvalidArgument` | Eine Feld-ID außerhalb des Bereichs, eine Skalarbreite ungleich 1/2/4/8 Bytes, ein nicht existierender Deskriptor-Feldtyp — oder, bei aktivierter Strict-UTF-8-Prüfung, ein `string`-Wert, der sich nicht als gültiges UTF-8 kodieren lässt (§6.4). |
| `InvalidMessage` | Fehlgeformte Nachricht beim Dekodieren: jede §5.2.2-Bedingung. Entspricht dem `INVALID`-Ergebnis. **Abschneidung ist nicht `InvalidMessage`** — aber Eingabe, die *sowohl* fehlgeformt als auch abgeschnitten ist, ist es, per Vorrang aus §5.2.3. |
| `LimitExceeded` | Ein konfiguriertes Receiver-Limit (§6.2.1) wurde auf einem schema-**unbeschränkten** Feld überschritten. Die Nachricht ist **wohlgeformt** — dieselben Bytes dekodieren unter einem lockereren Limit — also ist das **nicht** `InvalidMessage` und **nicht** das `INVALID`-Ergebnis. Eine terminale, empfängerlokale **Policy**-Zurückweisung. Nie für ein Feld erhoben, das das Schema beschränkt. |

**Decode-Ergebnis vs. Fehlercode.** Das Pro-`feed`/`decode`-Resultat eines Decoders ist
das dreiwertige **Ergebnis** (§5.2), *nicht* ein Code aus dieser Tabelle. `INVALID`
entspricht `InvalidMessage`. `INCOMPLETE` ist **kein** Fehler und **DARF NICHT** als
`InvalidMessage` gemeldet werden; es wird dem Aufrufer gereicht, der es nach seinem Framing
beurteilt — und es gibt keinen `finish`-Schritt, der es umwandelt (§5.2.4). Diese Tabelle
deckt die *anderen* fehlbaren Operationen ab — Enkodieren und Argumentprüfungen.

**Ein typ-fehlangepasstes Read ist gar kein Fehler.** Ein Read zu binden, dessen
deklarierter Typ dem Draht widerspricht, ist der MESSAGE_SPEC-§7.3-Fall: Das Feld **MUSS**
wie eine unbekannte ID übersprungen werden, das Ziel bleibt unberührt. Es ist weder
`InvalidMessage` noch ein Argumentfehler, und ein Decode, dem sonst nichts begegnet, bleibt
`COMPLETE`. Es gibt daher **keinen** Code für „ungültige Benutzung": Jeder verbleibende
Aufrufer-Fehler ist `InvalidArgument`, jede verbleibende fehlgeformte Eingabe
`InvalidMessage`.

**`LimitExceeded` ist die eine Decode-Pfad-Ausnahme dieser Teilung.** Es beendet einen
Decode auf *wohlgeformter* Eingabe, und das dreiwertige Ergebnis hat keinen Wert für
„gültig, aber mehr, als ich zu akzeptieren konfiguriert bin". Eine Implementierung **MUSS**
beides für den Aufrufer unterscheidbar halten — eine Limit-Zurückweisung heißt *„hebe mein
Limit an oder der Sender muss weniger schicken"*, `INVALID` heißt *„diese Bytes sind
kaputt"*. **Wie** es auftaucht, bleibt offen: als **viertes Decode-Ergebnis** oder als
terminales Scheitern mit dem `LimitExceeded`-Code auf dem Fehlerkanal. So oder so **DARF**
es **NICHT** als `InvalidMessage` gemeldet werden.

**Erweiterung der Menge.** Das ist die gemeinsame Basis. Sprach- oder plattformspezifische
Bedingungen **DÜRFEN** sie erweitern oder verfeinern — ein I/O-Fehler eines Stream-Sinks,
ein Allokationsfehler einer Managed-Runtime, ein Encoding-Fehler einer Standardbibliothek —
solange die Basisbedeutungen erhalten bleiben.

**Exceptions vs. Return-Codes:**

* Wo Exceptions der **idiomatische Standard** sind (Python, Java, C#), ist Werfen in
  Ordnung — die Codes auf Exception-Typen abbilden;
* wo sie **nicht verfügbar, teuer oder üblicherweise verboten** sind (C, embedded /
  `no_std`, Realtime- oder Kernel-Targets, `-fno-exceptions`-Builds), **keine Exceptions
  verwenden**: auf dem Hot Path einen Statuscode oder ein Result-/`Result`-artiges Objekt
  zurückgeben, damit eingeschränkte Aufrufer nie dafür zahlen.

### 6.4 String-Gültigkeit: UTF-8 (`SOFAB_STRICT_UTF8`, normativ)

Eine `string`-Nutzlast ist **UTF-8** (§4.6); `blob` ist der Typ für opake Bytes (die
Produzentenregel steht in MESSAGE_SPEC §8). Ein `string`, dessen Bytes kein gültiges UTF-8
sind, ist fehlgeformt: zurückweisen — beim Decode als `INVALID` (§5.2.2), beim Encode als
`InvalidArgument` (§6.3).

Die Validierung hängt an einer kanonischen Option, **`SOFAB_STRICT_UTF8`** (Schreibweise
anpassen). Sie ist eine **Validierungs-Policy, nie ein Wire-Format-Schalter**: Sie
entscheidet nur Annehmen-oder-Ablehnen und ändert nie, wie gültige Daten kodiert werden —
zwei Peers mit verschiedenen Einstellungen interoperieren auf allen gültigen Daten.

#### 6.4.1 Die zwei Zustände

**ON (Default) — ungültiges UTF-8 wird zurückgewiesen, symmetrisch:**

* *Decode*: eine ungültige-UTF-8-`string`-Nutzlast, **die gelesen wird**, ist `INVALID` —
  dieselbe terminale Klasse wie jede andere Fehlform-Bedingung, kein Längen-/Limit-Fehler;
* *Encode*: ein `string`-Wert, der sich nicht als gültiges UTF-8 kodieren lässt —
  Nicht-UTF-8-Bytes in einem Byte-Container-Typ, ein **ungepaartes Surrogat** in einem
  UTF-16-/Unicode-Typ — wird mit `InvalidArgument` verweigert. Die Encode-Seite ist es, die
  MESSAGE_SPEC §8s produzentenseitiges **DARF NICHT** durchsetzt: Ohne sie können die
  Encoder eines strikten Ökosystems Bytes emittieren, die dessen Decoder zurückweisen.

**OFF (Opt-out) — die Validierung entfällt, aber das erlaubte Verhalten ist festgelegt,
nicht implementierungsdefiniert: roh oder ablehnen, nie stumm verlustbehaftet.**

| String-Typ des Targets | Verhalten bei Prüfung OFF |
|---|---|
| **Byte-Container** (C `char[]`, C++ `std::string`, Go `string`, Zig `[]const u8`) | speichern die Wire-Bytes **wörtlich** — untranscodiert, aber dennoch **kopiert** in das Ziel des Aufrufers (§6.7.3). Codepoints zu interpretieren ist Sache der Anwendung. **Diese Targets MÜSSEN die Option anbieten.** |
| **Unicode-Strings** (Rust `String`, Java/C# `string`, JS-Strings, Python `str`) | können keine Nicht-UTF-8-Bytes halten; ihre einzige nicht-verändernde Option ist der **strikte/fatale** Konstruktor, sie sind also **immer strikt**. Die Option ist ein No-op und **DARF ganz entfallen**, dokumentiert als immer-ON. |

**Stummes Ersetzen ist in jedem Modus verboten (normativ).** Eine Implementierung **DARF**
für einen ungültigen-UTF-8-`string` **NICHT** `U+FFFD` (oder irgendeinen Ersatz)
einsetzen, Bytes verwerfen oder einen leeren/abwesenden Wert erzeugen — in keiner
Richtung, in keinem Modus (MESSAGE_SPEC §8). Plattform-Default-Encoder sind oft
verlustbehaftet — Javas `getBytes(UTF_8)` und JavaScripts `TextEncoder` ersetzen ungepaarte
Surrogate durch `U+FFFD`. Die strikten/fatalen Varianten verwenden.

#### 6.4.2 Default und Platzierung

`SOFAB_STRICT_UTF8` ist per Default **ON** — die Default-Konfiguration ist damit die, unter
der die gemeinsamen Vektoren (§7.1) und der differenzielle Fuzzer laufen. Für
Unicode-Targets ist Strenge durch den ohnehin nötigen Transcode bereits bezahlt; für
Byte-Container ist ein richtiger Validator billig neben dem Decode selbst.

**Eingeschränkte/Footprint-Profile DÜRFEN per Default OFF sein oder die Prüfung ganz
herauskompilieren** (null `.text`/`.rodata`-Kosten bei OFF) — die
Constrained-Profile-Erlaubnis aus §6.2. Ein solcher Build ist ein dokumentierter
Nicht-Strikt-Build, und die CI des Targets **MUSS** die Prüfung-ON-Konfiguration weiterhin
bauen und konformitätstesten.

**Wo der Schalter lebt** (Byte-Container-Targets), folgt dem Ort, an dem die Corelib ihre
Konfiguration ohnehin hält: *Compile-Zeit* (`#define`, ein Zig-Build-Feature) für
Footprint-Targets; *Laufzeitoption* (ein Decoder-/Encoder-Konfigurationsfeld, wie in Go)
neben den bestehenden Decode-Limits. C++ darf beides.

#### 6.4.3 Das `utf8_valid`-Primitiv

Wo **generierter Code** — nicht die Corelib — den String in einem **Byte-Container**-Target
materialisiert (Zig), stellt die Corelib `utf8_valid(bytes) -> bool` bereit, und der
Generator emittiert einen **unbedingten** Aufruf. Das Gate lebt im Primitiv: Es faltet zu
`true`, wenn OFF kompiliert, und liest sonst die Laufzeitoption.

* Das Flag umzulegen erfordert also nie ein Neugenerieren von Code.
* Generierter Code ist über Build-Konfigurationen identisch.
* In codegen-materialisierten **Unicode**-Targets (Rust, Java, C#) nutzt generierter Code
  den strikten Konstruktor; kein Primitiv nötig.

**Validator-Korrektheit (normativ).** `utf8_valid` — und jede corelib-interne Prüfung — ist
ein echter UTF-8-Validator, kein Byte-Bereichs-Kurzschluss. **Das ist eine
Sicherheitsoberfläche.** Er **MUSS** zurückweisen:

* Overlong-Kodierungen, einschließlich `C0 80` (Javas „Modified UTF-8"-NUL);
* Surrogat-Codepoints `U+D800`–`U+DFFF`;
* Codepoints über `U+10FFFF`.

Die meisten Sprachen haben einen Stdlib-Validator zum Einhängen; C und C++ brauchen einen
handgeschriebenen, getesteten.

**Eingebettetes U+0000 ist erlaubt.** NUL ist gültiges UTF-8 und in der längen-gerahmten
Nutzlast darstellbar (§4.6); der Validator **DARF** es **NICHT** zurückweisen, während die
Overlong-Form `C0 80` wie jede Overlong-Kodierung zurückgewiesen werden **MUSS**.
*(Nicht-normativer Interop-Hinweis: NUL-terminierte Konsumenten schneiden am ersten NUL ab.
Die Corelib-API ist längen-begrenzt, aber Produzenten mit solchen Konsumenten SOLLTEN
eingebettetes NUL meiden oder `blob` verwenden — MESSAGE_SPEC §8.)*

#### 6.4.4 Chunk-übergreifende Semantik (normativ)

UTF-8-Gültigkeit ist eine Eigenschaft der **vollständigen Nutzlast** des String-Feldes —
die Fixlen-Länge ist vorab bekannt — und **eine Chunk-Grenze DARF das Ergebnis NICHT
beeinflussen.** Ein Decoder DARF inkrementell validieren, sofern er Validator-Zustand über
`feed`-Aufrufe trägt; ein Sammelpuffer ist nicht nötig.

| Situation | Ergebnis |
|---|---|
| Mehrbyte-Sequenz am **Chunk-Ende** geteilt | `INCOMPLETE` — ein wohlgeformter Präfix, den weitere Bytes vervollständigen können. `INVALID` zu melden — oder den String fallen zu lassen — ist die Anti-Falt-Verletzung aus §5.2.1. |
| Mehrbyte-Sequenz am **Nutzlast-Ende** abgeschnitten (deklarierte Länge mitten in der Sequenz erreicht) | `INVALID` — kein weiteres Byte gehört zu diesem String |
| ein Byte, das keine gültige Sequenz beginnen oder fortsetzen kann (`0xFF`, ein loses Fortsetzungsbyte) | `INVALID` — aber gemeldet **bei Nutzlast-Abschluss**, nicht vorher |

Die letzte Zeile ist die eine Stelle, an der §5.2.3s Vorrang das Urteil **nicht** vorzieht.
Ein Decoder **DARF** für ein solches Byte **NICHT** mitten in der Nutzlast `INVALID`
melden, solange die deklarierte Länge nicht erreicht ist; diese Eingabe ist `INCOMPLETE`,
bis die Nutzlast endet.

*Warum:* Diese Prüfung ist keine Eigenschaft des Drahts. `SOFAB_STRICT_UTF8` hat einen
normativen OFF-Modus, in dem dieselben Bytes akzeptiert werden, und validiert wird nur, wo
ein `string` **materialisiert** wird — nie beim Skip. Dieselbe Nutzlast ist also je nach
Build-Flag und danach, ob der Handler sie las, bereits gültig oder ungültig. Ließe man
zusätzlich das *Timing* das Urteil bestimmen, kämen zwei konforme Decoder bei
Annehmen-oder-Ablehnen auseinander — genau was MESSAGE_SPEC §7.1 verbietet und was das
Eröffnungsversprechen dieses Kapitels ausschließt.

#### 6.4.5 Übersprungene Felder werden nie validiert (normativ)

Skip bleibt, was es überall sonst ist: ein Längensprung über Bytes, die nicht inspiziert
werden (§5.2). UTF-8-Validierung läuft **nur, wo ein `string` materialisiert wird** — in
ein Ziel gelesen — nie beim Skip, in keinem Modus.

* Die Wire-Gültigkeit ungelesenen Inhalts liegt in der Verantwortung des **Produzenten**
  (MESSAGE_SPEC §8, durchgesetzt von der strikten Encode-Seite). Protobuf behandelt
  unbekannte Felder genauso.
* Das Decode-Ergebnis kann also davon abhängen, welche Felder der Handler liest. Die
  gemeinsamen Vektoren und die Treiber des differenziellen Fuzzers lesen **jedes** Feld —
  Konformitätsergebnisse bleiben deterministisch.
* Mit genau zwei Pro-Feld-Absichten (§6.7.2) wird ein gewolltes Feld immer **gelesen** und
  damit immer validiert; nur ein Feld, nach dem niemand fragte, nimmt den Skip-Pfad.

**Konformitätstests und der differenzielle Fuzzer laufen mit Prüfung ON** — zugleich der
ausgelieferte Default —, sodass jede Implementierung darin übereinstimmt, dass ein
ungültiger-UTF-8-`string` zurückgewiesen wird. Ein Deployment, das maximalen Durchsatz
braucht und beide Enden kontrolliert, darf sie abschalten; sprachübergreifende
Interoperabilität verlangt sie an.

### 6.5 Float-Bit-Exaktheit: die fp32-Signaling-NaN-Gefahr (normativ)

§4.6 verlangt, dass jeder Float — `NaN` eingeschlossen — **bit-für-bit** round-trippt. Für
`fp64` ist das gratis: ein natives 64-Bit-Double hält alle 64 Bits wörtlich. **`fp32`
trägt eine Repräsentationsgefahr**, und dieses Kapitel macht den Schutz dagegen normativ.

**Die Gefahr.** IEEE-754 unterscheidet zwei Arten von `NaN` am höchstwertigen Mantissenbit
(dem *Quiet*-Bit): quiet hat es gesetzt, signaling hat es gelöscht bei nicht-null Payload.
`fp32` auf einen breiteren Float zu weiten ist für ein signalisierendes NaN **nicht**
bit-erhaltend — die IEEE-Weitung **setzt das Quiet-Bit**:

```
fp32 sNaN   0x7F80_0001   ── auf Double weiten ──▶   qNaN   0x7FC0_0001
                    ▲ Quiet-Bit 0 (signaling)                ▲ Quiet-Bit 1 (quiet)
```

Die Payload ist **in dem Moment zerstört, in dem der Wert durch den breiteren Float geht**,
und kein späterer Code kann sie wiederherstellen. Ein Decoder, der ein `fp32` als
geweitetes Double zum Konsumenten oder in sein eigenes Re-Encode trägt, verliert das sNaN
und ändert die Wire-Bytes — eine §4.6-Verletzung.

**Wer handeln muss:**

| Target | Pflicht |
|---|---|
| **nativer `fp32`-Typ** (Rust `f32`, C, C++, Go, Java, C#, Zig `float`) | **nichts zu tun.** Die natürliche Implementierung hält die Payload in diesem Typ von Ende zu Ende — ein 4-Byte-Load/Store, kein `fp64` im Round-Trip-Pfad — ein sNaN round-trippt von selbst. Nur nicht *grundlos* auf Double und zurück weiten. |
| **nur-Double** (JavaScript/TypeScript, Python, Dart, Lua-Default-Build, und jede Sprache, deren einziger Float ein Double ist oder die `fp32` nur über Weitung materialisiert) | **MUSS** einen Roh-Wire-Bytes-Pfad bereitstellen (unten) |

**Anforderung (normativ).** Das §4.6-Ergebnis ist universell: Für **jede** Implementierung
**MUSS** Decode → Re-Encode jeder `fp32`-Nutzlast (signalisierendes NaN eingeschlossen) die
exakten 4 Wire-Bytes reproduzieren, an **jeder** `fp32`-Position — einem **skalaren**
`fp32` (§4.6) **und** jedem Element eines **`fp32`-Arrays** (§4.8). Unterschiedlich ist
nur, *wie* ein Target das erfüllt.

Nur-Double-Targets:

* **MÜSSEN** einen **Roh-Wire-Bytes**-Pfad für bit-exakte Konsumenten (Transcode,
  Round-Trip, jedes Re-Encode) bereitstellen, der diese Bytes **wörtlich** re-emittiert;
* **DÜRFEN** ein `fp32` **NICHT** aus dem geweiteten Wert re-enkodieren;
* **DÜRFEN** den Komfort-**Wert** für einen Wert-Konsumenten als geweitetes Double
  belassen — er muss nur wissen, dass der Wert `NaN` ist.

**Das gilt überall, wo ein `fp32` den Aufrufer erreicht** — der Visitor ist die einzige
Decode-Oberfläche (§5.3.1), es gibt also einen Ort, an dem es richtig sein muss; ein Port,
der seinen Round-Trip-Pfad schützt, aber nicht seinen Wert-Pfad, ist die Defektklasse, die
dieses Kapitel verhindern soll.

`fp64` braucht den Roh-Pfad in keiner Sprache.

**Wie (Nur-Double-Targets).** Die `fp32`-Nutzlast so ausliefern wie eine
`string`/`blob`-Nutzlast — rohe little-endian Wire-Bytes, kopiert in den Speicher des
Aufrufers, oder ein 32-Bit-Bits-Accessor — *neben* dem Komfortwert, und beim Re-Encode
diese Bytes direkt schreiben (nie `setFloat32` oder Reinterpretation aus dem Double). Den
Roh-Kanal als Opt-in gaten, falls Pro-Element-Roh-Auslieferung reines Wert-Array-Decoding
belasten würde.

**Testen (normativ).** Weil JSON-Vektoren `NaN` nicht darstellen können (§4.6, §7.1), wird
dies durch eine **implementierungseigene** Suite verifiziert, nicht die gemeinsamen
Vektoren: behaupten, dass ein signalisierendes, ein stilles und ein negatives `fp32`-NaN je
**bit-für-bit** round-trippt, an einer Skalar- **und** einer Array-Position, über Decode →
Re-Encode **und** jeden materialisierten Durchlauf. Der differenzielle SofaBuffers-Harness
(Crucible) prüft zusätzlich, dass alle Sprachtreiber auf jedem `fp32`-NaN bit-für-bit
übereinstimmen.

### 6.6 Speicher: der Codec ist heap-frei (normativ)

**Der Codec einer Corelib MUSS heap-frei sein.** Er führt **keinerlei** dynamische
Allokation durch: kein `malloc`, `realloc`, `free`, `new`, `delete`, kein Allocator-Aufruf,
kein eigener wachsender Container, keine Arena, kein zur Laufzeit dimensionierter Scratch —
auf keiner Seite, auf keinem Pfad, in keiner Build-Konfiguration. Jedes Byte, das er liest,
schreibt oder meldet, liegt in Speicher, den der **Aufrufer** bereitgestellt hat, oder in
**Zustand fester Größe, dessen Größe dieses Dokument festlegt** (§6.6.2).

Das ist strenger als die Regel, die es ersetzt — mit Absicht. Eine frühere Fassung verbot
nur Speicher, *dessen Größe die Nachricht bestimmt*, und ließ eine Implementierung frei zu
allokieren, solange die Zahl von woanders kam. Es brauchte dann zwei Regeln — eine über den
Mechanismus, eine über die Herkunft der Größe — und die zweite war nur durch Messung
prüfbar. **Eine Regel ersetzt beide:** Der Codec allokiert nicht. Eine Zahl, die nie einen
Allocator erreicht, kann von niemandem ausgenutzt werden, der sie gewählt hat.

Beides sind jetzt Verstöße, und der zweite ist der, den Ports falsch gemacht haben:

| Form | Urteil |
|---|---|
| der Codec ruft den Allocator seiner Sprache, für irgendetwas | **verstößt** — egal was die Größe bestimmt hat |
| der Codec ruft selbst nichts, **verlangt aber ein wachstumsfähiges Ziel** und lässt es wachsen — aus einem Wire-Zähler oder sonstwie | **verstößt** — er hat den Allocator-Aufruf einen Typ weiter geschoben, wo ein Quelltext-Audit ihn nicht mehr sieht |

**Die einmalige Konstruktion ist die Grenze.** Der eigene Zustand fester Größe des Codecs
muss irgendwo leben, und in einer Managed-Sprache ist das Objekt, das ihn hält, selbst
heap-allokiert. Den Encoder oder Decoder zu **konstruieren** — seinen Zustand nach den
Konstanten dieses Dokuments zu dimensionieren — ist die Handlung des Aufrufers, geschieht
**einmal, beim Setup**, und DARF allokieren. Das Verbot bindet alles **nach** der
Konstruktion: `write`, `feed`, `flush` und jeder Pfad, den sie erreichen, führen **null**
Allokationen aus. Ein Codec, der pro Nachricht, pro Feld oder pro Chunk allokiert, hat die
Regel gebrochen; einer, dessen Konstruktor seinen Zustand fester Größe einmal allokierte,
nicht — nichts auf dem Draht hat diese Größe gewählt, und nichts nach dem Setup allokiert
erneut.

**Wo dynamischer Speicher sonst erlaubt ist:** nur in der **statischen Helfer-Schicht**
(§6.6.1), und nur, wo der Codec nicht in sie hineinruft. Ein Helfer, den der Codec auf dem
Decode- oder Encode-Pfad aufruft, ist für die Zwecke dieses Kapitels Teil des Codecs —
egal in welcher Datei er liegt.

Was das kauft, und was zuvor Port für Port ausdiskutiert wurde: Ein Firmware-Target und ein
Server-Target führen denselben Code aus statt zweier Profile davon; ein Aufrufer kann den
Speicher eines Decodes per Konstruktion begrenzen statt per Messung; und „wer gibt das
frei" hört auf, eine Frage zu sein, die ein Port in seinem README beantwortet.

#### 6.6.1 Geltungsbereich: der Codec, nicht das Paket

Dieses Kapitel bindet den **Codec** — Encoder und Decoder, die Wire-Bytes anfassen.

Es bindet **nicht** die **statische Helfer-Schicht** daneben: die Reassembly-Puffer,
Sequence-Kollektoren und Array-Builder, die ein Port vorhält, damit der Generator sie nicht
in jedes generierte Paket emittieren muss (SofaBuffers ARCHITECTURE §8). Dieser Code gehört
der generierten Schicht, und die generierte Schicht allokiert. Er liegt zur Wiederverwendung
im Corelib-Repository, nicht weil er Teil des Codecs wäre — und **wer §6.6 auditiert, darf
das eine nicht mit dem anderen verwechseln.**

**Die Grenze ist der Call-Graph, nicht das Verzeichnis.** Ein Helfer liegt nur dann
außerhalb des Codecs, wenn **kein Codec-Pfad ihn aufruft**. Die generierte Schicht ruft den
Helfer, und der Helfer ruft den Codec — nie andersherum. Ein Port, dessen Decoder in einen
allokierenden Helfer greift, hat die Allokation zurück in den Codec geholt, wie auch immer
die Dateien angeordnet sind.

**Die generierte Schicht allokiert; der Codec nicht.** §5.1.2 sagt das fürs Enkodieren, und
fürs Dekodieren liest es sich identisch: Das generierte Objekt kennt das Schema,
dimensioniert und besitzt den Speicher, in dem jedes Feld landet, und treibt dann den Codec
darüber wie jeder andere Aufrufer. Ein Codec, der einen Wert materialisiert braucht, bittet
seinen Aufrufer um den Platz; er nimmt ihn nicht.

#### 6.6.2 Was eine Ausnahme ist und was nicht

**Reassembly ist keine Ausnahme.** Eine über gefütterte Chunks verteilte Nutzlast muss
irgendwo zusammengefügt werden (§5.2). Dieses Irgendwo ist Speicher des Aufrufers — der
Codec kopiert jedes Stück hinein, sobald es eintrifft, was die Chunk-Lebensdauer-Regel
(§6.0) ohnehin erzwingt. Ein Codec **DARF** stattdessen **NICHT** einen privaten
Akkumulator wachsen lassen. Ein *Helfer*, der genau das im Auftrag des Aufrufers tut, ist
die statische Helfer-Schicht aus §6.6.1 und nicht Gegenstand dieses Kapitels.

**Beschränkter Arbeitszustand ist erlaubt, weil er atomar ist — nicht, weil er klein ist.**
Ein Parse-Stack fester Größe, der `MAX_DEPTH`-Zähler, ein zurückgehaltener Header (§6.0.1),
ein partielles Varint, eine Landezone für einen über eine Chunk-Grenze geteilten Skalar —
alle existieren, damit das Ziel des Aufrufers **genau einmal, vollständig** geschrieben
wird. Ein Codec, der einen halb angekommenen Wert ins Ziel schriebe und später flickte,
zeigte einen Zustand, über den kein Aufrufer schließen kann. Ihre Größe kommt aus diesem
Dokument, die Nachricht kann sie also nicht wählen — und *das* macht sie konform. Klein zu
sein ist Folge, nicht Lizenz.

Dieses Kapitel **schreibt für solchen Zustand kein Design vor**: ein Skalar-Schieberegister,
ein festes Array, ein byteweiser Übertrag sind alle korrekt. Ein Port wählt, was seine
Sprache billig macht.

#### 6.6.3 Konsequenz für die Callback-Oberfläche

Ein Callback, der ein **materialisiertes Aggregat** liefert — einen ganzen `string`, ein
ganzes Byte-Array, eine ganze Elementliste —, zwänge den Codec, diesen Wert zu bauen, und
die einzige Größe, aus der er ihn bauen könnte, ist die des Drahts. Ports, die dieses
Kapitel erfüllen, liefern ein Aggregat daher entweder:

* **in Stücken**, mit dem Gesamt der Nutzlast, dem Offset dieses Stücks und dem eigenen
  Puffer des Aufrufers als Argumenten; **oder**
* **in ein Ziel, das der Aufrufer zurückreicht**, nachdem ihm der angekündigte Zähler
  genannt wurde — wobei der Codec ein zu kurzes Ziel zurückweist, statt es zu vergrößern.

Skalar-Callbacks sind unberührt: Sie tragen einen Wert, und ein Wert ist kein Speicher.

#### 6.6.4 Beidseitig geprüft

Die Regel gilt jetzt dem **Aufruf**, der Quelltext ist also wieder Beweismittel: kein
Allokationsprimitiv auf einem Codec-Pfad, und kein Codec-Pfad in einen allokierenden
Helfer (§6.6.1).

Quelltext-Inspektion allein reicht dennoch **nicht**, denn eine indirekte Allokation über
einen Aufrufer-Container hinterlässt kein `malloc` im Quelltext. Konformität verlangt daher
**beides**:

* **lesen** — von keinem Codec-Einstiegspunkt aus ist ein Allokationsprimitiv erreichbar;
* **messen** — eine Allokationszählung oder die Heap-Hochwassermarke über ein vollständiges
  Enkodieren und ein vollständiges Dekodieren, **gemessen nach der einmaligen Konstruktion
  des Codecs**, die null sein **MUSS** (§13).

### 6.7 Keine Views: der Codec kopiert (normativ)

**Eine Corelib DARF keine Zero-Copy-View auf irgendeinen dekodierten Wert anbieten.**
Jeder Wert, den der Codec liefert, wird **in Speicher des Aufrufers kopiert** — ein
`string`, ein `blob`, ein Skalar, ein Array-Element gleichermaßen — auf dem One-Shot-Pfad
exakt wie auf dem Streaming-Pfad. Es gibt keinen Payload-Positions-Getter, keinen
geliehenen Slice, keinen Wert „gültig bis zum nächsten feed" und keine Build-Option, die
eines davon wiederherstellt.

Eine frühere Fassung ließ einen Port die Byte-Position einer Nutzlast melden, damit ein
Aufrufer eine View darüber legen konnte. Das ist zurückgezogen — aus demselben Grund, auf
dem §6.6 ruht: **Der Aufrufer besitzt den Speicher, und der Codec hält keinen.**

* Eine View ist eine Behauptung über **Lebensdauer** — „diese Bytes bleiben, wo sie sind,
  und bleiben gültig, bis zu einem späteren Moment". Ein Codec, der keinen eigenen Speicher
  hält, hat nichts, worüber er diese Behauptung aufstellen könnte. Er behauptete eine
  Eigenschaft von Speicher, den er weder allokiert hat noch kontrolliert.
* Die Behauptung ist außerdem **nicht prüfbar**. Ihre beiden Bedingungen — die Nutzlast ist
  vollständig, die Nachricht erreichte `COMPLETE` — sind Bedingungen an die *Disziplin des
  Aufrufers*, und ein Port, der eine Position herausgibt, kann keine von beiden
  durchsetzen. Eine Regel, die eine Implementierung nicht durchsetzen kann, ist eine Regel,
  die im Feld gebrochen und nie gemeldet wird.
* Sie **spaltete eine Decode-Oberfläche in zwei** — eine, die materialisiert und validiert,
  und eine, die beides nicht tut — und der Unterschied war in den gemeinsamen Vektoren
  unsichtbar: Die feuern nur auf einen Wert, nach dem der Decoder gefragt wird.

**Was an ihre Stelle tritt:** nichts ist nötig. Ein Aufrufer, der eine Kopie vermeiden
will, behält die Eingabe-Bytes, die er gefüttert hat, und indiziert selbst hinein; er weiß,
was er gefüttert hat und wie lange dieser Speicher lebt — was der Codec nie wusste.

#### 6.7.1 Der One-Shot-Pfad hat keine Ausnahme

`decode(buffer)` kopiert auch. Dass der Aufrufer den ganzen Puffer stellt und über den
Aufruf am Leben hält, machte eine View *sicher* — aber es machte auch das
Speicherverhalten des Ports davon abhängig, welcher Einstiegspunkt benutzt wurde: Dasselbe
Schema trüge auf dem One-Shot-Pfad andere Speicherpflichten als auf dem Streaming-Pfad.
Diese Divergenz zu beenden ist, wofür §6.6 und §9.6 existieren.

#### 6.7.2 Konsequenzen für die Pro-Feld-Absichten

Es gibt genau **zwei** Pro-Feld-Absichten, und ein Port **DARF** keine dritte ergänzen:

| Absicht | Codec | Aufrufer |
|---|---|---|
| **read** | materialisiert ins Ziel des Aufrufers, und validiert | nimmt den Wert |
| **skip** | materialisiert nicht und validiert nicht (§6.4.5) | ignoriert das Feld |

Die `examine`-Absicht der früheren Fassung existierte nur, damit ein *ge-view-tes* Feld
nicht über `skip` läuft und so der UTF-8-Validierung entkommt. Mit dem Ende der Views ist
ein gewolltes Feld immer **read**, also immer validiert — der Fluchtweg, den sie
bewachte, kann nicht mehr entstehen.

#### 6.7.3 Strings bei Prüfung OFF werden trotzdem kopiert

§6.4.1 erlaubt einem Byte-Container-Target, Wire-Bytes **wörtlich** zu speichern, wenn
`SOFAB_STRICT_UTF8` OFF ist. Wörtlich heißt *untranscodiert*, nicht *unkopiert*: Die Bytes
werden unverändert in das Ziel des Aufrufers kopiert. Es gibt keinen Modus, in dem das Ziel
die Eingabe aliast.

---

## 7. Verpflichtende Unit-Tests

Jede `corelib-<lang>` **MUSS** Unit-Tests mitliefern, und diese Tests **MÜSSEN** gegen die
gemeinsame, sprachunabhängige Konformitäts-Suite validieren. Der Testordner folgt der
idiomatischen Konvention der Sprache — `tests/` in Rust und Python, `src/test/` in Java/C#,
`<pkg>_test.go`-Dateien in Go.

### 7.1 Die gemeinsamen Testvektoren verwenden

* **`test_vectors.json` aus `corelib-c-cpp` kopieren**, in den `assets/`-Ordner des neuen
  Repos (§8); die Suite liest sie von dort. Nie eine abweichende Kopie von Hand schreiben —
  `corelib-c-cpp` **generiert** sie und ist ihre Wahrheitsquelle (§2).
* **Die maßgebliche Formatbeschreibung ist `test_vectors_README.md`**, neben der Datei in
  `corelib-c-cpp/assets/` (§2). Für Top-Level-Schlüssel, Pro-Vektor-Felder, die
  `fields[]`-Operationen samt Parametern und die Darstellung von Floats/Blobs/Offsets gilt
  dieses Dokument — nicht irgendeine Kopie —, damit dieser Plan nie vom generierten Format
  wegdriften kann.
* **Die Datei ist nicht nur Vektoren.** Sie trägt Top-Level-Blöcke daneben:
  * `invalid_utf8` — Negativfälle für §6.4;
  * `sequence_growth` — die Fälle aus §7.2 Punkt 8, geschlüsselt über eine Folge von
    Element-IDs statt über einen Byte-String — weshalb sie keine Vektoren sein können.

  Ein Port führt **jeden** Block aus, den sein `requires`-Gating nicht ausschließt.
* **Abzudeckende Vektor-Kategorien:**
  * Skalare — unsigned, signed, bool, fp32, fp64, string, blob;
  * Feld-ID-Grenzen — `0` und `2.147.483.647`;
  * **alle drei Array-Wire-Typen** — Unsigned-Integer (`u8..u64`, `0b011`), Signed-Integer
    (`i8..i64`, `0b100`) und Fixlen/Float (`fp32`/`fp64`, `0b101`) einschließlich `±0` und
    `±inf`;
  * Sequences — verschachtelt, mit Skalaren und Arrays; Structs und Unions;
  * eine große Komposit-Nachricht, die alles mischt.

### 7.2 Erforderliche Testarten

**1. Vektor-Encode** — die `fields` jedes Vektors am gegebenen `offset` durch den Encoder
spielen; behaupten, dass die Bytes `serialized.hex` gleichen.

**2. Vektor-Decode** — `serialized.hex` in den Decoder füttern; behaupten, dass die
gewonnenen Felder/Werte `fields` entsprechen.

**3. Roundtrip** — encode → decode → vergleichen, für repräsentative Nachrichten.

**4. Chunked Streaming** — die definierende Anforderung:

* **In einen Puffer von exakt `MIN_OUTPUT_BUFFER` Bytes enkodieren**, den Sink wiederholt
  treibend; behaupten, dass die verkettete Ausgabe byte-identisch zur One-Shot-Ausgabe ist.
  Das eigene deklarierte Minimum des Ports, nicht bloß „kleiner als die Nachricht": Das ist
  die Größe, die die Konstante als real beweist. Eine `string`- oder `blob`-Nutzlast länger
  als der Puffer abdecken, damit der Teilbare-Läufe-Pfad geprüft wird, was auch immer
  deklariert ist.
* **Einen Puffer unter dem Minimum zurückweisen** — einen **mit Sink** installieren,
  `buflen - offset` ein Byte zu kurz; behaupten, dass es **dort** scheitert, per
  Out-of-Range-Mechanismus des Ports, nicht mitten in einer Nachricht (§5.1.4). Ein Port,
  der `1` deklariert, testet den Null-Länge-Puffer. Mit dem Gegenstück paaren: Derselbe zu
  kleine Puffer **ohne** Sink wird angenommen, und eine passende Nachricht enkodiert
  hinein — das Minimum **DARF NICHT** zum Boden des One-Shot-Pfads werden.
* **Über einen nehmenden Sink enkodieren** — ein Callback, das bei jedem Aufruf einen
  *anderen* Puffer installiert und den übergebenen vor der Rückkehr scrubbt; behaupten,
  dass die Ausgabe weiterhin der One-Shot-Ausgabe gleicht (§5.1.5). Ein Encoder, der in den
  weggegebenen Puffer weiterschriebe, läse das Füllmuster zurück — und der
  `MIN_OUTPUT_BUFFER`-Test oben bemerkte es nicht, denn dieser Sink kopiert und kehrt
  zurück. Mit einem **kopierenden** Sink paaren, der ohne Installation zurückkehrt, und
  dieselbe Ausgabe behaupten — beide Hälften des Vertrags abgedeckt.
* **Kein fremder Speicher, niemals** — einen `blob` mehrerer Puffergrößen enkodieren und
  behaupten, dass **jedes** Callback-Argument im installierten Puffer liegt (Identität
  vergleichen, oder dass der Pointer hineinfällt). Pass-Through ist verboten (§5.1.6),
  das muss also auf jedem Flush jeder Nachricht gelten — ohne Erlaubnis-Flag, ohne
  beanspruchbare Ausnahme.
* **Byteweise dekodieren** (und in ungeraden Chunk-Größen); behaupten, dass das Ergebnis
  identisch zum Füttern in einem Stück ist. Das beweist, dass die Zustandsmaschine an jeder
  Byte-Grenze pausiert und fortsetzt.
* **Jeden Chunk nach der `feed`-Rückkehr überschreiben** — mit Füllbyte scrubben oder
  freigeben — und behaupten, dass die dekodierte Nachricht unverändert ist. Das macht die
  Chunk-Lebensdauer aus §6.0 zur geprüften statt behaupteten Eigenschaft; nichts anderes in
  dieser Liste bemerkte einen Decoder, der einen Slice in einen gefütterten Chunk behielte.
* **Auch den One-Shot-Puffer überschreiben** — `decode(buffer)` ausführen, den ganzen
  Puffer scrubben und behaupten, dass die dekodierte Nachricht unverändert ist. Der
  One-Shot-Pfad hat keine View-Ausnahme (§6.7.1), und das ist der Test, der es beweist —
  ein Port, der aus dem übergebenen Puffer borgt, besteht jeden anderen Punkt dieser Liste.

**5. Fehlgeformte Eingabe** — jede §5.2.2-Bedingung **MUSS** `INVALID` liefern, nie
crashen: ein überlanges Varint, ein unbalanciertes Sequence-Ende, eine übergroße
ID/Länge/Zähler, Verschachtelung über `MAX_DEPTH`, ein reservierter Fixlen-Subtyp. Die
übergroße ID auch auf einem **Sequence-Ende**-Header abdecken, nicht nur auf einem
werttragenden: §6.2 kennt keine Ausnahme, und eine Implementierung, die die ID nur in den
Zweigen validiert, die sie *benutzen*, besteht den werttragenden Fall und verfehlt diesen.

**5b. Toleranz** — nicht-kanonische, aber wohlgeformte Eingabe **MUSS** zu dem Wert
dekodieren, den sie bezeichnet, und kanonisch re-enkodieren — nie `INVALID`:

* ein nicht-minimales Varint (§4.1.2) an einem Feld-Header, einem `fixlen_word` und einem
  Element-Zähler;
* ein **Sequence-Ende-Header mit nicht-null ID innerhalb `ID_MAX`** (§4.9), der als
  gewöhnliches Sequence-Ende dekodieren und als `0x07` re-enkodieren **MUSS**.

Das sind die Fälle, in denen ein Decoder *strikter* ist, als das Format erlaubt — der
Spiegel von Punkt 5, und die Fälle, die eine Mehrheits-Konformitätsprüfung nicht fangen
kann, da Implementierungen gleichförmig zu strikt sein können.

**6. Abschneidung** — eine mitten im Feld gekappte Nachricht (ein hängendes `0x80`, eine
Fixlen-Nutzlast kürzer als deklariert, eine ungeschlossene Sequence) **MUSS** `INCOMPLETE`
liefern, nicht `INVALID` und nicht `COMPLETE`; die fehlenden Bytes nachzufüttern
vervollständigt sie, und kein `finish`-Schritt befördert sie zum Fehler (§5.2.4).

Auch ein **nach seinem ersten Byte gekapptes `fixlen_word`** abdecken, dessen Byte einen
**reservierten Subtyp** (`0x4`–`0x7`) trägt: Der Subtyp steht mit den niederen 3 Bits
bereits fest, eine früh auswertende Implementierung antwortet also `INVALID`, wo §4.1.1
`INCOMPLETE` verlangt. Nichts anderes in dieser Liste prüft die
Keine-Teilauswertung-Regel — das hängende `0x80` oben trägt kein festgelegtes Teilfeld,
in das man spähen könnte.

**7. Skip** — dekodieren und dabei manche Felder und ganze Sub-Sequences ignorieren;
korrektes Wiederaufsetzen am Folgefeld behaupten.

**8. Sequence-Array-Wachstum** — die `sequence_growth`-Fälle aus `test_vectors.json`
(§7.1) abspielen. Die Länge eines Sequence-Arrays ist *höchste vorhandene ID + 1*
(MESSAGE_SPEC §5.1), seine Größe steht also erst am Array-Ende fest, und sein Container
wächst mit den eintreffenden Elementen — **in der statischen Helfer- / generierten Schicht
(§6.6.1), nie im Codec** — die eine Allokationsform, in der Wachstum konform ist
(ARCHITECTURE §9.5; alles mit Zähler oder Länge vor der Nutzlast prüft dieses Wort und
allokiert exakt es, einmal).

Nichts anderes in dieser Liste erreicht das: Zwei Ports, die verschieden wachsen,
emittieren identische Bytes und erreichen identische Ergebnisse — §7.1s Vektoren sind
strukturell blind dafür.

Pro Fall die resultierende **Container-Länge** und das **Ergebnis** behaupten — ohne
Allocator-Instrumentierung, was diese Fälle portabel macht:

* der Element-**Index** ist die Schranke: `id` an der Grenze cap-1 dekodiert; `id` am Cap
  ist `LimitExceeded` (§6.2.1) und allokiert vorher nichts;
* eine ID-Lücke unterhalb des Caps wird mit dem Element-Default gefüllt und verkürzt oder
  verschiebt das Array nicht;
* nach einer zurückgewiesenen ID bleibt der Container **nicht** teilweise erweitert, und
  eine danach gelieferte niedrigere ID landet weiterhin korrekt.

Wachstums-**Geometrie** — auf mindestens `id + 1` erweitern statt exakt `id + 1`, damit ein
dünn besetztes Array nicht O(n²) Kopien kostet — ist die eine Eigenschaft, die die
Allokationszählung der Sprache braucht. Testen, wo die Sprache eine bietet; wo nicht, im
README des Ports vermerken, statt den Fall als bestanden zu melden. Ein Port, der nie
wächst (ein statisch begrenztes Profil), ist durchs `requires`-Gating des Blocks
ausgeschlossen und vermerkt das stattdessen.

### 7.3 Coverage

Die Messlatte der bestehenden Ports halten: einen Coverage-Job in die CI hängen und ein
Badge im README zeigen. **Erwartete Coverage ist >90 %.**

---

## 8. Assets-Anforderung

In den `assets/`-Ordner des neuen Repositories kopieren:

| Datei | Aus | Verwendet von |
|---|---|---|
| `sofabuffers_logo.png`, `sofabuffers_icon.png` | `documentation/assets/` | dem README-Header (§9.1) |
| `test_vectors.json` | `corelib-c-cpp/assets/` — dort generiert, maßgeblich | der Test-Suite (§7.1) |

`test_vectors_README.md` bleibt in `corelib-c-cpp` und ist die maßgebliche Beschreibung des
Vektorformats; nicht kopieren. Raw-Links stehen in §2.

---

## 9. README-Format

Jedes `corelib-*`-README folgt **derselben Form**, damit ein Leser, der das README eines
Ports kennt, jedes andere navigieren kann. Die Struktur unten reproduzieren und die
Spezifika der Zielsprache einsetzen.

**Vor dem Bearbeiten eines READMEs den tatsächlichen Quellcode der Corelib lesen.** Jeder
Fakt, Befehl, jede Versionsnummer, Abhängigkeit, jedes Feature-Flag und jeder API-Name im
README **MUSS** dem heutigen Code entsprechen. Alles Veraltete, Ungenaue oder Irreführende
korrigieren.

#### 9.0.1 Das README stellt fest; es argumentiert nicht (normativ)

Es trägt **Fakten** — was die Library ist, was sie voraussetzt, was zu tippen ist, wie ein
Aufruf aussieht, wie die Zahlen lauten. Es trägt **nicht** die Begründungen dahinter. Drei
Prosa-Arten gehören nirgendwo hinein:

| raus | warum |
|---|---|
| **Begründung** — warum eine API ihre Form hat, warum ein Trade-off so ausging | dafür gibt es genau einen Ort: die Tabelle in §9.3 — eine Tabelle gerade deshalb, damit sie nicht zum Essay wachsen kann |
| **vorweggenommene Einwände** — Text, der eine Entscheidung gegen einen Leser verteidigt, der sie nicht erhoben hat | wer diese Auseinandersetzung will, sucht die Spezifikation |
| **Nacherzählung der Spezifikation** | `MESSAGE_SPEC.md` und dieses Dokument sind normativ und einen Link entfernt. Eine Paraphrase schafft eine zweite Quelle, die driftet — und die Drift bleibt unsichtbar, bis jemand der falschen Kopie vertraut. |

#### 9.0.2 Abschnitte: feste Reihenfolge, und was ergänzt werden darf

* **Die Abschnittsreihenfolge nicht ändern**, keine neuen Abschnitte erfinden. Das Verbot
  bindet auf **jeder Überschriftentiefe**, nicht nur `##` — ein neues `###` oder `####` in
  einem erlaubten Abschnitt ist der übliche Weg, auf dem diese Form verloren geht, und der
  Weg, auf dem ein README dreißig Überschriften erreicht, ohne eine einzige neue
  Top-Level-Sektion.
* **Ein Port DARF dennoch einen Abschnitt für etwas genuin Eigenes ergänzen** — eine
  Feature-Flag-Tabelle, Packaging für sein Ökosystem, die Target-Liste eines
  Multi-Plattform-Builds. Neun der zwölf Corelibs wuchsen unabhängig ein
  `## Feature flags` — diese Konvergenz ist, wie eine Lücke in diesem Kapitel aussieht,
  nicht wie Wildwuchs.
* Die vorgeschriebenen Abschnitte behalten Namen und Reihenfolge; eine Ergänzung verdrängt
  oder ersetzt nie einen.
* **Der Test für eine Ergänzung ist derselbe wie für alles andere hier:** Füllt sie
  **Fakt** — Schalter, Versionen, Koordinaten, Befehle, Targets —, gehört sie hinein, und
  ein Port mit solchen Dingen sagt sie unter eigener Überschrift, statt sie in einen
  Nachbarn zu schmuggeln. Füllt sie **Begründung**, gehört sie nicht hinein — und eine
  Überschrift ändert daran nichts.

#### 9.0.3 Der Löschtest (normativ)

**Ein Fakt darf das README nur verlassen, wenn er in der generierten API-Dokumentation
steht.** Steht er nirgends sonst, wird er nicht gelöscht — er wird zuerst in die
Doc-Kommentare geschrieben und danach hier entfernt. Was in keinem von beiden zu finden
ist, wird **gemeldet**, nie stillschweigend fallen gelassen.

Man beachte die Asymmetrie, denn sie ist der ganze Punkt: **Begründung zu streichen kostet
nie einen Fakt.** Jede Aussage, jedes Codebeispiel und jede Tabelle bleibt. Nichts hier
lizenziert das Entfernen einer Versionsnummer, einer Abhängigkeit, eines Befehls oder eines
Beispiels — und ein kürzeres README, das eines davon verlor, ist ein schlechteres README,
kein besseres.

Die Abschnitte, in dieser Reihenfolge:

### 9.1 Generischer Header-Block (zentriert)

* Zentriertes Logo: `<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>`
* `# SofaBuffers`
* Tagline: `<b>Structured Objects For Anyone</b><br>` + `<i>... so optimized, feels amazing.</i>`
* Ein Link zurück zur GitHub-Organisation.

### 9.2 `## SofaBuffers <Language> library`

Der Eröffnungsabschnitt, in dieser Reihenfolge:

* **Badges** — CI, Coverage und ein **Docs**-Badge. Das Docs-Badge verlinkt die
  API-Referenz auf GitHub Pages (§12.2) und ist der *einzige* Verweis auf
  API-Dokumentation im README.
* **GitHub-Link** — zum Repository dieses Ports / zur Organisation.
* **Kurzzusammenfassung** — ein Absatz dazu, was *diese* Library besonders macht: die
  Stärken der Sprache, die Streaming-Garantie, der kleine Footprint, sprachübergreifende
  Kompatibilität.
* **Requirements** — minimale Runtime-/Toolchain-Version plus Installationsbefehl
  (`cargo add`, `pip install`, `go get`, …).
* **Dependencies** — jede nicht-optionale Abhängigkeit mit Mindestversion, oder ein
  explizites „keine Laufzeitabhängigkeiten". Aktuell halten, während die Library sich
  entwickelt.

### 9.3 `## Why this design`

Eine zweispaltige Tabelle, die Designziele — Streaming-Ausgabe, Streaming-Eingabe, keine
unnötigen Kopien, wenig/keine Allokation auf dem Hot Path, kleiner Footprint,
Typsicherheit, sprachübergreifende Kompatibilität — darauf abbildet, wie *diese*
Implementierung sie erreicht. Das Tabellenformat behalten; es **MUSS** über die Ports
parallel bleiben.

**Die Tabelle ist der ganze Abschnitt**: kein Prosa-Absatz darüber oder darunter, eine
Zeile pro Zelle. Das ist die einzige sanktionierte Begründung des READMEs — hier landet der
Druck, sobald der Rest des Dokuments dafür geschlossen ist (§9.0.1) —, und Prosa neben der
Tabelle ist, wie dieser Trichter leckt.

### 9.4 Kein API-Dokumentationsabschnitt

**Es gibt kein API-Dokumentationskapitel.** Das **Docs**-Badge (§9.2) ist der einzige
Einstieg in die generierte API-Referenz. **Kein** `## Source documentation`,
`## API reference`, `## API documentation` oder Ähnliches ergänzen, und keinen generierten
Doku-Inhalt ins README kippen.

### 9.5 `## Usage`

Knappe, lauffähige Beispiele im idiomatischen Muster der Sprache, für jedes von:

* **Simple encode** — eine kleine Nachricht bauen, ihre Bytes erzeugen.
* **Simple decode** — Bytes zurück in Werte parsen.
* **Streaming einer Nachricht größer als der Puffer** — den Sink mit einem Ausgabepuffer
  kleiner als die Nachricht treiben.
* **OStream** — der Output-Stream- / Writer-Sink-Wrapper.
* **IStream** — der Input-Stream- / Push-Feed-Wrapper.
* **Generator** — generierter Objektcode: die One-Shot-`encode()` / `decode()`-Helfer
  *und* der Streaming-`serialize` / `decoder()`-Pfad (§6.1.1). Der häufigste reale
  Anwendungsfall — explizit zeigen.

### 9.6 `## Memory handling`

**Nur** Eigentum und Lebensdauer der Nachrichtenpuffer beschreiben — wer welchen allokiert,
wem er gehört, wie lange er leben muss. Daraus **kein** API-Verzeichnis machen.

* **Ausgabepuffer (Enkodieren)** — wem der beschriebene Puffer gehört (**immer dem
  Aufrufer**: die Library allokiert oder vergrößert nie einen, §5.1.2) und was passiert,
  wenn er voll ist (Flush-Sink / Wiederverwendung vs. Buffer-Full-Fehler). Hier
  `MIN_OUTPUT_BUFFER` des Ports nennen (§5.1.4) und dass es einen **mit Sink**
  installierten Puffer bindet: Es ist die Zahl, die ein Aufrufer braucht, bevor er einen
  Streaming-Puffer dimensionieren kann. Festhalten, dass ein Sink **nur je** Speicher
  innerhalb des installierten Puffers erhält — Pass-Through ist verboten (§5.1.6) —, damit
  ein Leser, der einen Sink schreibt, weiß, dass es keinen zweiten Fall gibt.
* **Eingabepuffer (Dekodieren)** — wem die geparsten Bytes gehören und wie lange sie den
  Aufruf überleben müssen. **Hier gibt es nichts zu wählen:** Der Codec kopiert jeden
  dekodierten Wert in Speicher des Aufrufers, auf dem One-Shot-Pfad exakt wie auf dem
  Streaming-Pfad (§6.6). Sagen, wem die Eingabe-Bytes gehören und bis wann; die Regel nicht
  nacherzählen.
* **Keine Views** — schlicht festhalten, dass jeder dekodierte Wert in das Ziel des
  Aufrufers kopiert wird und nichts, was der Decoder erzeugt, die Eingabe aliast — auf dem
  One-Shot-Pfad wie auf dem Streaming-Pfad (§6.7). Ein Port hat hier nichts zu
  qualifizieren; beschreibt ein README einen geliehenen Wert, ist das README oder der Port
  falsch.

Schlicht festhalten, dass kein Wire-Wert im Codec eine Allokation bestimmt (§6.6) —
einschließlich dessen, dass es keinen library-eigenen Akkumulator für chunk-überspannende
Felder gibt — und woher der Speicher kommt, in dem jedes dekodierte Feld landet. Liefert
der Port eine **statische Helfer-Schicht** neben dem Codec (ARCHITECTURE §8), das sagen —
und sagen, dass sie im Auftrag der generierten Schicht allokiert, damit ein Leser ihre
Puffer nicht als §6.6-Verstoß liest (§6.6.1).

Wo es hilft, eine kurze Eigentums-/Lebensdauer-Tabelle für die beiden Puffer ergänzen. Die
Formulierungen über die Ports parallel halten.

### 9.7 `## Build & test`

Wie die Library gebaut und die Test-Suite ausgeführt wird, einschließlich der gemeinsamen
Vektoren aus `assets/`. Knapp halten — die Befehle und je ein Satz.

### 9.8 `## Benchmarks`

Wie die `perf`- und `bench`-Tools laufen (§10) und **was jedes misst** (`perf` =
CPU-unabhängige Kosten pro Op; `bench` = Durchsatz in MB/s auf der aktuellen Maschine).

Wo eine Sprache **zwei** Corelibs für **verschiedene Anwendungsfälle** hat (ein genereller
Build vs. ein `no_std`-/Embedded-Build), einen letzten Unterabschnitt ergänzen, der:

* den vorgesehenen Anwendungsfall jeder Implementierung erklärt, und
* eine Benchmark-Vergleichstabelle enthält, die zeigt, warum es beide gibt und wann welche
  vorzuziehen ist.

---

## 10. Performance-Tests

Jedes `corelib-*`-Repo liefert **drei** Benchmark-Tools, im idiomatischen Benchmark-Ordner
der Sprache (`benches/` in Rust, `cmd/perfbench/` in Go, ein Benchmark-Modul in
Python/Java/C#):

| Tool | misst | beantwortet |
|---|---|---|
| **`perf`** | CPU-geschwindigkeitsunabhängige Kosten pro Op — Zyklen/Op per Hardware-Zähler, oder Instruktionszahl unter einem Profiler | „wie gut ist die Implementierung?" — maschinenneutral |
| **`bench`** | praktischen Durchsatz auf der aktuellen Maschine, in MB/s | „wie schnell ist sie hier, jetzt?" |
| **`run_callgrind.sh`** | Instruktionen pro Op (Callgrind `Ir/op`) | die deterministischen, maschinenunabhängigen Kosten pro Op — auf *jedem* Target verfügbar, ohne „Zykluszähler nicht verfügbar"-Fallback |

**Die exakten Workloads, Datensätze, Zeitmessregeln, die Durchsatzformel und die
Ausgabegrammatik stehen in [`BENCH_SPEC.md`](BENCH_SPEC.md) — der einzigen
Wahrheitsquelle.** Alle drei Tools folgen ihr, damit die Zahlen über Sprachen vergleichbar
sind. Workloads, Zeitmessung oder Ausgabeformat hier nicht neu definieren.

---

## 11. Dev-Container

Jedes `corelib-<lang>`-Repository enthält einen `.devcontainer/`-Ordner mit einer
reproduzierbaren Entwicklungsumgebung auf Basis von Docker und VS Code Dev Containers.

### 11.1 Erforderliche Dateien

| Datei | Zweck |
|---|---|
| `Dockerfile` | Baut das Image: Ubuntu-24.04-Basis, Sprach-Toolchain, GitHub CLI (`gh`), Node.js LTS und Claude Code (`@anthropic-ai/claude-code`). |
| `start.sh` | Startet den Container interaktiv, mountet den Workspace und ein benanntes `claude-config`-Volume, lädt `.devcontainer/.env` per `--env-file`, falls vorhanden (warnt, wenn nicht). |
| `devcontainer.json` | Referenziert das `Dockerfile`, lädt `.devcontainer/.env` per `runArgs`, deklariert VS-Code-Extensions — sprachspezifische Tools **plus** `anthropic.claude-code`. |
| `.env.example` | Committetes Template mit jeder unterstützten Umgebungsvariable (mindestens `GH_TOKEN`). Jede Variable trägt einen Kommentar zu Zweck und nötigen Scopes. |

### 11.2 `.env`-Datei (Secrets)

* `.devcontainer/.env` hält echte Secrets und wird **nie committet**.
* Sie **MUSS** in `.gitignore` stehen — verpflichtend in jedem `corelib-*`-Repository.
* Entwickler kopieren `.env.example` → `.env` und tragen Werte ein.
* `start.sh` übergibt `--env-file "$SCRIPT_DIR/.env"` an `docker run`, wenn die Datei
  existiert.
* `devcontainer.json` übergibt `"--env-file", "${localWorkspaceFolder}/.devcontainer/.env"`
  in `runArgs`, damit VS Code dieselben Variablen lädt.

> **Hinweis:** Weil `runArgs` immer `--env-file` enthält, **muss die `.env`-Datei
> existieren**, bevor das Projekt in VS Code als Dev Container geöffnet wird. Zuerst
> `.env.example` → `.env` kopieren — auch mit lauter leeren Werten.

### 11.3 VS-Code-Extensions (`devcontainer.json`)

Mindestens deklarieren:

* **Sprach-Extensions** — Debugger, Formatter/Linter und jede idiomatische Test-Runner-
  oder Build-Tool-Integration (siehe `corelib-c-cpp` als konkretes Beispiel).
* **`anthropic.claude-code`** — in jedem Port erforderlich.

---

## 12. GitHub-Workflows

Jedes `corelib-<lang>`-Repository liefert unter `.github/workflows/`:

| Workflow | erforderlich | Kapitel |
|---|---|---|
| **CI** | immer | §12.1 |
| **Docs** | immer | §12.2 |
| **Versionskonsistenz** | wo der Baum eine prüfbare Version trägt | §12.3 |

**Dateinamen sind Konvention, nicht normativ.** `ci.yml`, `docs.yml` und
`version-consistency.yml` sind die Namen der Familie, aber ein Repository, dessen
Docs-Workflow `build-doxygen.yaml` heißt, ist konform, und `.yml` und `.yaml` sind dieselbe
Datei. Was dieses Kapitel festlegt, sind **Trigger, Einstellungen und Reihenfolge** — nie
der Name.

**Zwei weitere Dateien sind erlaubt; keine ist erforderlich:**

* eine wiederverwendbare **`workflow_call`**-Datei für einen Build, der sich pro Target
  wiederholt, aufgerufen aus der CI;
* ein **Release**-Workflow, wo die Sprache in eine Paket-Registry publiziert (crates.io,
  PyPI, npm, …). Eine Corelib ohne Paket hat keinen, und eine mit Paket ist nicht
  verpflichtet, das Publizieren hier zu automatisieren.

**Eine Pipeline pro Ereignisklasse.** Alles, was auf einen **Branch-Push oder Pull Request**
läuft, gehört in eine Pipeline: `needs:` kann Workflow-Dateien nicht überqueren, ein Target
in eigener Datei kann also nie hinter irgendetwas sequenziert werden. Tag-getriggerte
Workflows stehen außerhalb dieser Regel — sie beantworten ein anderes Ereignis und haben
nichts, hinter dem sie sequenziert würden.

### 12.1 CI — Build & Test (`ci.yml`)

Läuft auf jedem Push nach `main` **und** jedem Pull Request auf `main`.

#### 12.1.1 Matrix-Build (optional)

Eine Matrix lohnt, wo Versionsunterschiede echte Divergenz verursachen:

* **Skript-/interpretierte Sprachen** (Python, Node.js/TypeScript) —
  Standardbibliotheksverhalten unterscheidet sich zwischen Runtime-Versionen, also aktuelle
  Stable und mindestens ein Vorgänger-Release testen;
* **compiler-versionierte Sprachen** (C/C++, Rust) — mehrere Compiler (GCC + Clang, Rust
  stable + beta) decken Portabilitätsprobleme auf.

Für eine stabile Single-Vendor-Toolchain, deren Versionsunterschiede Library-Code selten
berühren (Go, Java, C#), genügt eine gepinnte Version.

**Wird eine Matrix verwendet, `fail-fast: false` setzen**, damit ein Fehlschlag auf einem
Bein die anderen nicht abbricht — alle Ergebnisse müssen sichtbar sein.

* Deshalb **DARF** eine Matrix auch **NICHT** zu einem einzelnen Job gefaltet werden, der
  über ihre Werte schleift — so verlockend die Setup-Kosten pro Bein sind: Die Schleife
  meldet ein Urteil, wo die Matrix eines pro Wert meldete.
* **Eine Achse in *Steps* zu falten ist erlaubt**, sofern jeder Step `if: always()` trägt,
  damit ein scheiternder die nachfolgenden nicht verbirgt. Das erhält Name, Dauer und Log
  jedes Wertes; was es aufgibt, ist eine Zeile pro Wert in der Checks-Liste. Nur für eine
  Achse verwenden, deren Werte **eine Umgebung teilen** — etwa vier Compile-Flag-Sätze.
  Eine Achse mit verschiedenen Umgebungen (eine Runtime-Version, eine Cross-Toolchain)
  **bleibt eine Matrix**.

Die offizielle Setup-Action der Sprache verwenden (`dtolnay/rust-toolchain`,
`actions/setup-python`, `actions/setup-go`, `actions/setup-java`, `actions/setup-node`) und
deren eingebauten Dependency-Cache aktivieren.

```yaml
strategy:
  fail-fast: false
  matrix:
    version: ["<current-stable>", "<previous-stable>"]
    os: [ubuntu-latest]          # windows-latest / macos-latest für Cross-Plattform-Targets ergänzen
```

#### 12.1.2 Erforderliche Workflow-Einstellungen

**Eine `concurrency`-Gruppe auf Workflow-Ebene**, damit ein überholter Push seine
Runner-Slots freigibt, statt sich hinter sich selbst einzureihen:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
```

* `cancel-in-progress` ist auf `main` bewusst **aus**: Ein Push dort muss seinen vollen
  Lauf behalten, einschließlich der Coverage- und Badge-Jobs, die nur dort laufen. **Das
  ist die eine Einstellung hier ohne Ermessensspielraum pro Repository** — ein Repository,
  das auf `main` cancelt, verliert ein Badge-Update, wann immer zwei Pushes kurz
  nacheinander landen.
* Eine wiederverwendbare `workflow_call`-Datei deklariert **keine eigene Gruppe**. Sie
  läuft im Lauf des aufrufenden Workflows und ist von dessen Gruppe bereits abgedeckt; eine
  zweite Gruppe stritte nur mit der ersten um denselben Lauf.

**`timeout-minutes` auf jedem Job, der Steps ausführt.** GitHubs Default ist 360 Minuten,
und ein festgefahrener Job hält einen Runner-Slot für alle davon. Nicht hypothetisch: Ein
`apt-get install` in dieser Familie lief **87 Minuten** und kehrte zweimal nie zurück.

* Grob das **Vierfache** der normalen Job-Dauer wählen.
* **Jeden Netzwerk-Fetch, den der Workflow selbst ausführt** — `apt-get`, `curl`, `wget` —
  in einen begrenzten Retry wickeln. Die `setup-*`-Actions und den Paketmanager der
  Sprache **nicht** wickeln; sie retryen und cachen selbst.
* **Ein Job, der nur per `uses:` delegiert, ist ausgenommen** — mechanisch: Er kann
  `timeout-minutes` gar nicht tragen. Die Schranke gehört auf die Jobs des aufgerufenen
  Workflows, wo die Steps sind.

#### 12.1.3 Erforderliche Steps

1. `actions/checkout@v4`
2. Runtime aus `matrix.version` aufsetzen, Caching aktiviert.
3. Abhängigkeiten installieren / wiederherstellen.
4. In **beiden** Konfigurationen bauen, Debug und Release.
5. Die volle Test-Suite ausführen, einschließlich der gemeinsamen Vektoren aus `assets/`
   (§7).
6. Coverage-Report mit dem idiomatischen Tool der Sprache erzeugen (`cargo llvm-cov`,
   `coverage.py`/`pytest-cov`, `gcov`/`gcovr`, `go test -cover`, JaCoCo, Coverlet).
7. Zu einem Coverage-Dienst hochladen (Codecov oder gleichwertig) und das Badge ins README
   hängen (§9.2).

#### 12.1.4 Reihenfolge: das Fan-out gaten

Die Steps 1–3 sind billig, und jedes Bein wiederholt sie. Wo ein Repository breit
auffächert, läuft ein **Gate-Job zuerst**, und alles andere deklariert `needs:` darauf —
ein kaputter Baum wird einmal entdeckt statt einmal pro Bein. In einem Repository mit
vielen Targets ist das der Unterschied zwischen **51 Runner-Minuten und 28 Sekunden** für
dieselbe Erkenntnis.

**Beide Hälften des Gates sind bedingt, und ein Repository, das keine rechtfertigt, ist
ohne Gate konform:**

| Hälfte | gilt nur, wo |
|---|---|
| **Lint-Gate** | die Sprache bereits einen im Baum konfigurierten Linter hat. Einen einzuführen, um dieses Kapitel zu erfüllen, ist nicht der Punkt: Eine Corelib, deren Build `mvn -B verify` oder `dotnet test` ist, ohne Linter daneben, hat nichts zu gaten. |
| **Compile-only-Gate** | das Fan-out groß genug ist, die serialisierte Minute zu bezahlen — grob Faktor vier zwischen Fan-out-Kosten und Gate-Kosten. Eine Matrix aus drei Runtime-Versionen oder vier Compile-Konfigurationen liegt darunter. |

**Das Gate kompiliert und testet nicht** — ein Gate, das die Suite ausführt, ist eine
zweite Pipeline, kein Gate. Wo der Linter bereits kompiliert
(`cargo clippy --all-targets`), *ist* der Lint-Job das Gate, und ein separater Build-Job
kompilierte denselben Baum nur zweimal.

### 12.2 Docs — API-Dokumentation (`docs.yml`)

Läuft nur auf Push nach `main`, **nicht** auf Pull Requests.

| Sprache | Tool |
|---|---|
| C / C++ | Doxygen |
| Rust | `cargo doc` |
| Python | Sphinx (`sphinx-apidoc` + HTML-Builder) |
| TypeScript | TypeDoc |
| Go | `pkgsite` / `godoc -http` statischer Export |
| Java | Javadoc (`mvn javadoc:javadoc` oder `gradle javadoc`) |
| C# | DocFX |

**GitHub-Pages-Deployment — Actions-basiert, kein `gh-pages`-Branch.** Die Pages-Einstellung
des Repositories (Settings → Pages → Build and deployment → Source) **MUSS**
**„GitHub Actions"** sein.

```yaml
permissions:
  pages: write
  id-token: write
```

**Erforderliche Steps**

1. `actions/checkout@v4`
2. Runtime aufsetzen, auf aktuelle Stable gepinnt (keine Matrix nötig).
3. Abhängigkeiten installieren.
4. HTML-Dokumentation in einen lokalen Ordner generieren (`docs/html/`, `target/doc/`,
   `site/`).
5. Als Pages-Artefakt hochladen:
   ```yaml
   - uses: actions/upload-pages-artifact@v3
     with:
       path: <html-output-folder>
   ```
6. Deployen:
   ```yaml
   - uses: actions/deploy-pages@v4
   ```

**Veröffentlichte URL:** `https://sofa-buffers.github.io/<repo>/` — das Ziel des
**Docs-Badges** (§9.2).

**Warum das eine eigene Datei bleibt.** Der Docs-Workflow besitzt eine
`concurrency`-Gruppe auf Workflow-Ebene, damit zwei Pages-Deployments nie rennen können.
Ein Workflow darf nur eine solche Gruppe halten, und die CI braucht ihre eigene fürs
Cancel-bei-Überholung (§12.1.2) — die beiden können sich also keine Datei teilen. Die
Trennung hält zudem `pages: write` und `id-token: write` aus dem Workflow heraus, der baut
und testet — auf den Deploy-Job beschränken.

### 12.3 Versionskonsistenz (`version-consistency.yml`)

Läuft **nur auf Tag-Pushes**:

```yaml
on:
  push:
    tags: [ 'v*' ]
```

Er vergleicht den Tag, ohne führendes `v`, gegen die Version in jedem Manifest, das das
Repository liefert — `Cargo.toml`, `package.json`, `pubspec.yaml`, `pom.xml`, die
`.csproj`, `build.zig.zon`, `conanfile.py`, `library.json`, die CMake-`project()`-Version,
`__version__` — und lässt den Tag bei jeder Abweichung scheitern.

**Der Trigger ist kein Detail.** Ein Vergleich ist nur sinnvoll, wenn es einen Tag zum
Vergleichen gibt — und zwischen Releases darf ein Manifest dem neuesten Tag legitim
vorauslaufen: Ein Repository, das 0.11.0 vorbereitet, während `v0.10.0` der neueste Tag
ist, ist korrekt, nicht kaputt. Die Prüfung auf `main` oder Pull Requests verglich die
Manifeste gegen den zufällig neuesten Tag — was über den geprüften Commit nichts sagt.

**Zwei Fälle haben nichts zu prüfen und DÜRFEN diesen Workflow NICHT tragen:**

* **Go** — die Modul-Version *ist* der Tag und steht nirgends im Baum;
* jede Corelib, die **noch kein erstes Release geschnitten hat**.

Die Regel verallgemeinert über Go hinaus: Wo der Tag die einzige Quelle der Version ist,
gibt es keine zweite Kopie, die ihm widersprechen könnte.

---

## 13. Konformitäts-Checkliste

Eine neue `corelib-<lang>` ist konform, wenn:

**Identität und API-Oberfläche**

- [ ] Alle öffentlichen Symbole leben im `sofab`-Namespace; das Registry-Paket heißt
      `SofaBuffers` (§6).
- [ ] Die API-Versions-Konstante / der Getter liefert `1` (§6.2).
- [ ] Die Generated-Object-Oberfläche verwendet nur die geschlossene Namensmenge aus
      §6.1.1, und die Streaming-Primitive genügen, um eine dünne generierte Schicht zu
      bauen, deren One-Shot-`encode()`/`decode()` Wrapper über den Streaming-Pfad sind
      (§6.1).

**Wire-Format**

- [ ] Varint- und Zick-Zack-Encode/Decode entsprechen §4.1–4.2 exakt, einschließlich
      Minimalform-Encode, nicht-minimal-tolerantem Decode und der 10-Byte-/64-Bit-Schranke
      (§4.1.2–4.1.3).
- [ ] Kein Teil eines unvollständigen Varints wird ausgewertet — ein festgelegtes
      Low-3-Bit-Teilfeld beeinflusst nie ein Ergebnis (§4.1.1).
- [ ] Feld-Header-Packung `(id << 3) | typ` und alle 8 Wire-Typen (§4.3).
- [ ] Fixlen-Wort `(länge << 3) | fixlen_typ`, LE-Floats, UTF-8-Strings ohne Terminator,
      Blobs (§4.6).
- [ ] Integer-Arrays, und Fixlen-Arrays mit einem geteilten Fixlen-Wort; keine dynamischen
      Subtypen in Fixlen-Arrays; die §4.8.1-Decode-Reihenfolge (§4.7–4.8).
- [ ] Sequence-Start/Ende-Framing, frischer ID-Scope, Ein-Byte-`0x07`-Ende, ID verworfen
      aber weiter durch `ID_MAX` beschränkt, Skip-durch-Ablaufen mit Tiefenzähler,
      Zurückweisung jenseits `MAX_DEPTH` = 255 (§4.9).

**Enkodieren**

- [ ] Der Encoder kann die kanonische Sequence-Kodierung von MESSAGE_SPEC §2 in einem
      **einzigen Vorwärtslauf** erzeugen — ein All-Default-`struct`/`union`-Feld
      weggelassen, ein All-Default-Wrapper-Array-Element weiterhin gerahmt — entweder über
      eine Deskriptor-/Objektschicht, die pro Feld vor dem Öffnen entscheidet, oder über
      die `begin_lazy` / `end` / `end_keep`-API (§6.0.1). Zurückgehaltene Header machen die
      Bytes nie von der Ausgabepuffergröße abhängig.
- [ ] **Streaming-Encode** in einen Puffer kleiner als die Nachricht per Flush-Callback /
      Sink, mit Mid-Stream-Buffer-Swap, über einen **Aufrufer-Puffer** mit Start-Offset —
      die Corelib allokiert gar keinen Ausgabepuffer; die generierte Schicht tut es und
      reicht einen herein wie jeder andere Aufrufer (§5.1).
- [ ] **`MIN_OUTPUT_BUFFER` deklariert** (§5.1.4), höchstens 20, im Memory-Abschnitt des
      READMEs genannt (§9.6), auf jedem **mit Sink** installierten Puffer durchgesetzt und
      auf keinem anderen, und als Größe im §7.2-Punkt-4-Encode-Test verwendet.
- [ ] Der Vertrag des zurückkehrenden Flush-Callbacks hält in beide Richtungen: Rückkehr
      ohne Installation setzt bei Offset 0 fort, ein nehmender Sink installiert vor der
      Rückkehr einen Ersatz (§5.1.5).
- [ ] **Kein Pass-Through** — ein Sink erhält nur je Speicher innerhalb des installierten
      Puffers, auf jedem Flush jeder Nachricht; es gibt keine Erlaubnis, die das
      wiederherstellt (§5.1.6). Getestet durch §7.2 Punkt 4.

**Dekodieren**

- [ ] **Streaming-Decode** per `feed` beliebig kleiner Chunks, Push-Callback / Pull-Read,
      späte Feldbindung und Auto-Skip, mit Rückgabe von `COMPLETE` / `INCOMPLETE` /
      `INVALID` und **ohne** `finish`/`finalize`-Schritt — `INCOMPLETE` wird gereicht, nie
      automatisch zum Fehler befördert (§5.2).
- [ ] `INVALID` gewinnt über `INCOMPLETE`, und jedes Konstrukt wird dort validiert, wo
      seine beschreibenden Bytes gelesen werden — bevor die von ihnen beschriebene Nutzlast
      konsumiert oder erwartet wird (§5.2.3).
- [ ] **Chunk-Lebensdauer** eingehalten: Ein gefütterter Chunk ist nur für die Dauer von
      `feed` geliehen (§6.0).
- [ ] **Der Visitor ist die einzige Decode-Oberfläche** — jeder Port bietet ihn an (in
      einer Sprache ohne Objekte als Callbacks mit Kontext-Pointer), und **kein Port bietet
      eine zweite**: keinen Pull-Parser, Iterator, Cursor oder Convenience-Wrapper, der auf
      anderem Weg dekodiert. Keine Ausnahme für eingeschränkte Targets (§5.3.1).

**Speicher**

- [ ] **Der Codec ist heap-frei (§6.6)** — kein `malloc`/`realloc`/`free`, kein
      `new`/`delete`, kein Allocator-Aufruf, kein eigener wachsender Container, und kein
      Vergrößern eines Aufrufer-Ziels — auf keiner Seite, auf keinem Pfad, in keiner
      Build-Konfiguration. **Beidseitig verifiziert** (§6.6.4): Von keinem
      Codec-Einstiegspunkt ist ein Allokationsprimitiv erreichbar, **und** eine
      Allokationszählung oder Heap-Hochwassermarke über ein vollständiges Enkodieren und
      Dekodieren — gemessen nach der einmaligen Konstruktion — ist **null**. Zustand fester
      Größe, durch die Konstanten dieses Dokuments beschränkt, ist keine Allokation. Gilt
      dem **Codec**; die statische Helfer-Schicht daneben (ARCHITECTURE §8) gehört der
      generierten Schicht und darf allokieren — aber nur, wo kein Codec-Pfad in sie ruft
      (§6.6.1).
- [ ] **Receiver-Limits vorhanden und endlich** — `max_dyn_array_count`,
      `max_dyn_string_len`, `max_dyn_blob_len`, ohne Unset- oder Unlimited-Zustand,
      geliefert von generiertem Code, durchgesetzt am Zähler-/Längen-Header (bei einem
      Sequence-Array am Element-Index) vor jeder Allokation, und **zurückgewiesen, nie
      geclampt** (§6.2.1).
- [ ] **Keine Views (§6.7)** — der Codec bietet keine Zero-Copy-View, keinen
      Payload-Positions-Getter und keinen geliehenen Wert, auf dem One-Shot-Pfad wie auf
      dem Streaming-Pfad. Jeder dekodierte Wert wird in das Ziel des Aufrufers kopiert.
      Bewiesen durch Scrubben des One-Shot-Puffers nach der `decode`-Rückkehr (§7.2
      Punkt 4).
- [ ] **Genau zwei Pro-Feld-Absichten** — `read` und `skip`, nie eine dritte. Es gibt kein
      `examine`, denn ohne Views wird ein gewolltes Feld immer gelesen und damit immer
      validiert (§6.7.2).

**Fehler, Strings, Floats**

- [ ] Ergebnis-/Fehlermeldung folgt den §6.3-Basiscodes — idiomatische Exceptions, wo die
      Sprache sie standardmäßig nutzt, sonst Return-Codes / Result-Objekte. Ein
      typ-fehlangepasstes Read ist ein Skip, kein Fehler. `LimitExceeded` bleibt von
      `InvalidMessage` unterscheidbar (§6.3).
- [ ] UTF-8-Gültigkeitsvertrag nach §6.4 — Byte-Container-Targets bieten
      `SOFAB_STRICT_UTF8` (per Default ON; eingeschränkte Profile dürfen per Default OFF
      sein oder es herauskompilieren), Unicode-Targets sind immer strikt (Option
      weglassbar), symmetrisch (`INVALID` beim Decode, `InvalidArgument` beim Encode), OFF
      festgelegt auf roh-oder-ablehnen (nie stummes `U+FFFD`/verlustbehaftet),
      übersprungene Felder nie validiert, `utf8_valid` bereitgestellt, wo Codegen
      Byte-Container-Strings materialisiert, Chunk-Grenzen ändern das Ergebnis nie, und
      Konformitätstests laufen mit Prüfung ON.
- [ ] **`fp32`-Bit-Exaktheit (§6.5)** — ein signalisierendes, ein stilles und ein negatives
      `fp32`-NaN round-trippt je bit-für-bit an einer Skalar- **und** einer Array-Position.
      Native-`fp32`-Targets bekommen das gratis; Nur-Double-Targets liefern den
      Roh-Wire-Bytes-Pfad und re-enkodieren nie aus dem geweiteten Wert.

**Tests und Repository**

- [ ] Alle gemeinsamen **Testvektoren** bestehen für Encode und Decode, plus Chunked-,
      Roundtrip-, Fehlform-, Toleranz-, Abschneidungs- und Skip-Tests (§7.2 Punkte 1–7).
- [ ] Die `sequence_growth`-Fälle bestehen, mit Behauptung von Container-Länge und Ergebnis
      pro Fall — Index-Schranke, Lückenfüllung, keine Teilerweiterung nach zurückgewiesener
      ID (§7.2 Punkt 8). Wachstums-Geometrie getestet, wo die Sprache Allokationen zählen
      kann, als ungetestet dokumentiert, wo nicht; ein Port, der nie wächst, ist per
      `requires` ausgeschlossen und sagt das.
- [ ] Coverage >90 %, in die CI gehängt, mit README-Badge (§7.3).
- [ ] `assets/` nach §8 befüllt — Branding aus `documentation`, `test_vectors.json` aus
      `corelib-c-cpp`.
- [ ] README folgt dem Familienformat mit Badges und den geforderten Abschnitten (§9).
- [ ] README trägt Fakten, keine Rechtfertigung: keine Begründung außerhalb der
      §9.3-Tabelle, keine vorweggenommenen Einwände, keine Nacherzählung der Specs. Ein
      Abschnitt jenseits der §9-Form ist in Ordnung, wo der Port etwas Eigenes
      festzustellen hat — Feature-Flags, Packaging, Targets — sofern er Fakten feststellt
      (§9.0.1–9.0.2).
- [ ] `perf` (CPU-unabhängig), `bench` (MB/s) und `run_callgrind.sh` (Callgrind `Ir/op`)
      vorhanden und lauffähig (§10).
- [ ] `.devcontainer/` vorhanden mit `Dockerfile`, `start.sh`, `devcontainer.json` und
      `.env.example`; `devcontainer.json` listet sprachpassende Extensions und
      `anthropic.claude-code`; `.devcontainer/.env` ist gitignored (§11).

**CI**

- [ ] CI baut und testet auf Push und PR; eine Matrix wird verwendet, wo
      Versionsunterschiede zählen; Coverage hochgeladen und das Badge im README (§12.1).
- [ ] Jede ereignisgetriggerte Workflow-Datei deklariert eine `concurrency`-Gruppe, mit
      `cancel-in-progress` aus auf `main`; eine wiederverwendbare `workflow_call`-Datei
      deklariert keine und ist von der ihres Aufrufers abgedeckt (§12.1.2).
- [ ] Jeder Job, der Steps ausführt, deklariert `timeout-minutes`, und jeder
      Netzwerk-Fetch, den der Workflow selbst ausführt, steckt in einem begrenzten Retry
      (§12.1.2).
- [ ] Alles, was auf einen Branch-Push oder Pull Request läuft, lebt in einer Pipeline,
      damit ein Gate dem Fan-out vorangehen kann, wo eines gerechtfertigt ist — ein
      Lint-Gate, wo ein Linter konfiguriert ist, ein Compile-only-Gate, wo das Fan-out groß
      genug ist, es zu bezahlen. Ein Repository mit keinem von beiden ist ohne Gate konform
      (§12.1.4).
- [ ] Der Versionskonsistenz-Workflow triggert nur auf Tag-Pushes und vergleicht den Tag
      gegen jedes Manifest des Repositories — oder fehlt bewusst, weil der Tag die einzige
      Version ist (§12.3).
- [ ] Der Docs-Workflow generiert HTML-Doku und publiziert per Actions-basiertem Deployment
      auf GitHub Pages (kein `gh-pages`-Branch); das Docs-Badge verlinkt die
      veröffentlichte Seite (§12.2).

---

*Dieses Dokument ist Teil des SofaBuffers-`documentation`-Repositories und die
sprachunabhängige Spezifikation des Formats. Die gemeinsame `test_vectors.json` ist
maßgeblich für jedes Detail, das hier nicht vollständig erfasst ist.*
