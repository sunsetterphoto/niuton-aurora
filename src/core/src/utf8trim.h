#pragma once

#include <QByteArray>

namespace aurora {

// Kürzt ein UTF-8-Byte-Array auf eine gültige Zeichengrenze: entfernt am Ende
// eine angeschnittene Mehrbyte-Sequenz, damit QString::fromUtf8 kein U+FFFD
// einfügt. Bereits ungültiges UTF-8 im Input wird nicht repariert.
inline QByteArray trimAufUtf8Grenze(const QByteArray &raw)
{
    int i = raw.size();
    // höchstens 3 Fortsetzungsbytes (10xxxxxx) zurückgehen
    while (i > 0 && (static_cast<unsigned char>(raw[i - 1]) & 0xC0) == 0x80
           && raw.size() - i < 3) {
        --i;
    }
    if (i == 0)
        return raw;
    const unsigned char lead = static_cast<unsigned char>(raw[i - 1]);
    int erwartet = 1;
    if ((lead & 0x80) == 0x00) erwartet = 1;        // ASCII
    else if ((lead & 0xE0) == 0xC0) erwartet = 2;
    else if ((lead & 0xF0) == 0xE0) erwartet = 3;
    else if ((lead & 0xF8) == 0xF0) erwartet = 4;
    const int vorhanden = raw.size() - (i - 1);
    if (vorhanden < erwartet)
        return raw.left(i - 1);   // Lead-Byte samt Rest der Sequenz weglassen
    return raw;
}

} // namespace aurora
