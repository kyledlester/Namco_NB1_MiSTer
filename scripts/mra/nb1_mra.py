#!/usr/bin/env python3
# Namco NB-1 MiSTer core -- MRA generator and validator (M2).
# Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
#
# Subcommands
#   extract   MAME source (ROM_START) + `mame -listxml` -> games/<set>.json
#             (ROM metadata only: names, sizes, CRC32/SHA1, load types, offsets)
#             plus the board description (M7: the KEYCUS answer derived from
#             MAME's custom_key_r for the set, see keycus_from_source)
#   generate  games/<set>.json -> MRA (ROM stream index 0, board record
#             index 2, check record index 3)
#   keycus    MAME source -> the KEYCUS description of every NB-1/NB-2 set
#             (research table; writes nothing)
#   validate  MRA + games/<set>.json [+ --listxml] [+ --zip]:
#             1. rebuild the index-0 stream exactly as MiSTer's mra_loader.cpp
#                does (interleave/map/repeat semantics, emulated below) from
#                SYNTHETIC file contents, and compare it byte for byte with
#                MAME's region assembly (ROM_LOAD / ROM_LOAD32_WORD / ...)
#                placed into the NB-1 platform map;
#             2. check names/sizes/CRCs against MAME metadata, the map against
#                rtl/nb1/nb1_mem_pkg.sv, the stream length, and that the check
#                record's entries cover every stream byte exactly once with
#                CRCs equal to MAME's file CRCs (or to the CRC of the fill);
#             2a. the board record (index 2) equals the JSON description
#                 (and, with --mame-src, MAME's custom_key_r for the set);
#             3. with --zip (the owner's local ROM set): assemble the real
#                stream in memory and verify every check-record CRC on it.
#                Nothing derived from ROM contents is written anywhere.
#
# The only game data this script ever writes is MAME metadata (JSON) and the
# MRA/check record (file names, CRC32s, sizes, fill CRCs).
import argparse, binascii, hashlib, json, os, re, struct, sys, zipfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))

# ---------------------------------------------------------------------------
# NB-1 platform map (must equal rtl/nb1/nb1_mem_pkg.sv; checked by `validate`).
# (name, region id, SDRAM/stream base, window size, MAME region tag)
PLATFORM_MAP = [
    ('OBJ',     3, 0x0000000, 0x1000000, 'c355spr'),
    ('CHR',     4, 0x1000000, 0x0400000, 'c123tmap'),
    ('VOICE',   2, 0x1400000, 0x0200000, 'c352'),
    ('PROG',    0, 0x1600000, 0x0100000, 'maincpu'),
    ('SHAPE',   5, 0x1700000, 0x0080000, 'c123tmap:mask'),
    ('C75DATA', 1, 0x1780000, 0x0080000, 'c75data'),
    ('C75BIOS', 6, 0x1800000, 0x0004000, 'mcu:internal'),
    ('KEYDATA', 7, 0x1804000, 0x0000020, 'proms'),
]
STREAM_END = 0x1804020
IOCTL_ROM, IOCTL_BOARD, IOCTL_CHECK = 0, 2, 3
IOCTL_NVRAM, NVRAM_BYTES = 1, 2048   # M18: EEPROM 28C16 image (rtl/nb1/nb1_nvram.sv)
RBF = 'Namco_NB1'
MAX_ENTRIES = 32

def fail(msg):
    print('FAIL:', msg)
    sys.exit(1)

# ---------------------------------------------------------------------------
# KEYCUS description from MAME (docs/M7_RESEARCH.md sections 2-6)
#
# namconb1_state::custom_key_r(offs_t offset) is a 32-bit handler: offset n
# covers 16-bit words 2n (bits 31:16, the lower address) and 2n+1 (bits
# 15:0) of the 16-word KEYCUS window. Per m_gametype it returns constants
# (the part's ID) and m_count (host rand(), "never the same twice in a
# row"), shifted into one half or the other; everything else returns 0.
KC_CASE_RE = re.compile(r'\bcase\s+(NAMCONB[12]_\w+)\s*:(.*?)(?=\bcase\s+NAMCONB[12]_|\n\t\}\n)', re.S)
KC_OFF_RE = re.compile(r'\bcase\s+(\d+)\s*:\s*return\s+([^;]+);')
KC_NONE = {'mode': 0, 'id': 0, 'id_word': 0, 'rnd_word': 0}

def keycus_types(src):
    body = src[src.index('::custom_key_r('):]
    body = body[:body.index('\n}\n')]
    out = {}
    for gt, blk in KC_CASE_RE.findall(body):
        words = {}
        for off, expr in KC_OFF_RE.findall(blk):
            n = int(off)
            for term in expr.replace('(', ' ').replace(')', ' ').split('|'):
                t = ' '.join(term.split())
                hi = t.endswith('<< 16')
                v = t[:-5].strip() if hi else t
                w = 2 * n + (0 if hi else 1)
                if v == 'm_count':
                    words[w] = 'rnd'
                elif re.fullmatch(r'0x[0-9a-fA-F]+|\d+', v):
                    if int(v, 0) != 0:
                        words[w] = int(v, 0)
                else:
                    fail('custom_key_r %s: cannot parse %r' % (gt, t))
        ids = [(w, v) for w, v in words.items() if v != 'rnd']
        rnd = [w for w, v in words.items() if v == 'rnd']
        if len(ids) > 1 or len(rnd) > 1 or (bool(ids) != bool(rnd)):
            fail('custom_key_r %s does not fit the ID + changing-word model: %r' % (gt, words))
        if ids:
            out[gt] = {'mode': 1, 'id': ids[0][1], 'id_word': ids[0][0], 'rnd_word': rnd[0]}
        else:
            out[gt] = dict(KC_NONE)
    return out

def keycus_from_source(src, setname):
    m = re.search(r'\bGAME\(\s*\d+\s*,\s*%s\s*,[^)]*?\binit_(\w+)\s*,' % re.escape(setname), src)
    if not m:
        fail('no GAME() line for ' + setname)
    init = m.group(1)
    g = re.search(r'::init_%s\(\)\s*\{[^}]*?m_gametype\s*=\s*(\w+)\s*;' % init, src)
    if not g:
        fail('init_%s sets no m_gametype' % init)
    kc = dict(keycus_types(src).get(g.group(1)) or KC_NONE)
    kc['part'] = ('C%d' % kc['id']) if kc['mode'] else ''
    kc['source'] = 'custom_key_r %s (init_%s)' % (g.group(1), init)
    return kc

def board_bytes(game):
    kc = game['board']['keycus']
    if kc['mode'] not in (0, 1) or not (0 <= kc['id_word'] < 16) or not (0 <= kc['rnd_word'] < 16) \
       or not (0 <= kc['id'] < 0x10000):
        fail('board.keycus out of range')
    if kc['mode'] and kc.get('part') != 'C%d' % kc['id']:
        fail('board.keycus part %r does not match the ID $%04X' % (kc.get('part'), kc['id']))
    # v2 (M16): byte 13 = the game's orientation in quarter turns CW (MAME ROT; control composition)
    rot = game.get('rotate', 0)
    if rot not in (0, 90, 180, 270):
        fail('rotate %r is not a MAME orientation' % rot)
    b = b'NB1B' + bytes([2, 16, 0, 0, kc['mode'], kc['id_word']]) + struct.pack('<H', kc['id']) \
        + bytes([kc['rnd_word'], rot // 90, 0, 0])
    assert len(b) == 16
    return b

def cmd_keycus(a):
    src = open(a.mame_src, encoding='utf-8').read()
    sets = re.findall(r'\bGAME\(\s*\d+\s*,\s*(\w+)\s*,', src)
    print('set          mode  ID     part  ID word (addr)   changing word (addr)  source')
    for st in sets:
        kc = keycus_from_source(src, st)
        if kc['mode']:
            print('%-12s %d     $%04X  %-5s %2d (+$%02X)         %2d (+$%02X)             %s' % (
                st, kc['mode'], kc['id'], kc['part'], kc['id_word'], 2 * kc['id_word'],
                kc['rnd_word'], 2 * kc['rnd_word'], kc['source']))
        else:
            print('%-12s 0     -      -     -                -                     %s' % (st, kc['source']))

# ---------------------------------------------------------------------------
# extract
LOAD_RE = re.compile(r'\b(ROM_LOAD(?:32_WORD|32_BYTE|16_BYTE|16_WORD_SWAP)?)\s*\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*CRC\(([0-9a-fA-F]+)\)\s*SHA1\(([0-9a-fA-F]+)\)')
REGION_RE = re.compile(r'\bROM_REGION(\w*)\s*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"\s*,\s*([^)]*)\)')

def parse_rom_start(src, setname):
    m = re.search(r'ROM_START\(\s*%s\s*\)(.*?)ROM_END' % re.escape(setname), src, re.S)
    if not m:
        fail('ROM_START(%s) not found' % setname)
    body = m.group(1)
    if re.search(r'ROM_(CONTINUE|FILL|RELOAD|COPY|IGNORE)\b', body):
        fail('unsupported ROM macro in ROM_START(%s)' % setname)
    regions, cur = [], None
    for line in body.splitlines():
        r = REGION_RE.search(line)
        if r:
            flags = r.group(4)
            cur = {'tag': r.group(3), 'size': int(r.group(2), 16), 'width': r.group(1) or '',
                   'fill': 0xFF if 'ERASEFF' in flags else 0x00, 'loads': []}
            regions.append(cur)
            continue
        l = LOAD_RE.search(line)
        if l:
            cur['loads'].append({'kind': l.group(1), 'name': l.group(2), 'offset': int(l.group(3), 16),
                                 'length': int(l.group(4), 16), 'crc': l.group(5).lower(),
                                 'sha1': l.group(6).lower()})
        elif 'ROM_LOAD' in line:
            fail('unparsed ROM_LOAD line: ' + line.strip())
    return regions

def cmd_extract(a):
    src = open(a.mame_src, encoding='utf-8').read()
    regions = parse_rom_start(src, a.set)
    root = ET.parse(a.listxml).getroot()
    mach = {m.get('name'): m for m in root.iter('machine')}
    if a.set not in mach:
        fail('%s not in listxml' % a.set)
    g = mach[a.set]
    lx = {r.get('name'): r for r in g.findall('rom')}
    for reg in regions:                     # cross-check every load against -listxml
        for ld in reg['loads']:
            r = lx.get(ld['name'])
            if r is None or r.get('region') != reg['tag'] or int(r.get('size')) != ld['length'] \
               or r.get('crc') != ld['crc'] or r.get('sha1') != ld['sha1'] \
               or int(r.get('offset'), 16) != ld['offset']:
                fail('listxml disagrees with source for %s' % ld['name'])
    if len(lx) != sum(len(r['loads']) for r in regions):
        fail('listxml lists ROMs the source parse missed')
    # device ROMs (C75 internal BIOS) come from the device's own listxml entry
    dev = {d.get('tag'): d.get('name') for d in g.findall('device_ref')}
    c75 = mach.get(dev.get(':mcu', ''))
    if c75 is None:
        fail('C75 device entry missing from listxml')
    b = c75.find('rom')
    regions.append({'tag': 'mcu:internal', 'size': int(b.get('size')), 'width': '', 'fill': 0,
                    'device': c75.get('name'),
                    'loads': [{'kind': 'ROM_LOAD', 'name': b.get('name'), 'offset': 0,
                               'length': int(b.get('size')), 'crc': b.get('crc'), 'sha1': b.get('sha1')}]})
    disp = g.find('display')
    out = {
        'set': a.set, 'parent': g.get('cloneof') or '', 'description': g.findtext('description'), 'year': g.findtext('year'),
        'manufacturer': g.findtext('manufacturer'), 'rotate': int(disp.get('rotate', '0')),
        'mame': {'version': root.get('build'), 'source': os.path.basename(a.mame_src),
                 'note': a.note or ''},
        'regions': regions,
        'board': {'keycus': keycus_from_source(src, a.set)},
    }
    with open(a.out, 'w', newline='\n') as f:
        json.dump(out, f, indent=1)
        f.write('\n')
    print('wrote', a.out)

# ---------------------------------------------------------------------------
# MAME region assembly and platform placement
def mame_region(reg, files):
    buf = bytearray([reg['fill']]) * reg['size']
    for ld in reg['loads']:
        d = files[ld['name']]
        o, n, k = ld['offset'], ld['length'], ld['kind']
        if k == 'ROM_LOAD':
            buf[o:o+n] = d
        elif k == 'ROM_LOAD32_WORD':
            for i in range(0, n, 2):
                buf[o + 2*i: o + 2*i + 2] = d[i:i+2]
        elif k == 'ROM_LOAD32_BYTE':
            for i in range(n):
                buf[o + 4*i] = d[i]
        elif k == 'ROM_LOAD16_BYTE':
            for i in range(n):
                buf[o + 2*i] = d[i]
        else:
            fail('unsupported load kind ' + k)
    return buf

def region_extent(reg):
    e = 0
    for ld in reg['loads']:
        k, o, n = ld['kind'], ld['offset'], ld['length']
        if k == 'ROM_LOAD':         end = o + n
        elif k == 'ROM_LOAD32_WORD': end = (o & ~3) + 2*n
        elif k == 'ROM_LOAD32_BYTE': end = (o & ~3) + 4*n
        else:                        end = (o & ~1) + 2*n
        e = max(e, end)
    return e

def platform_stream(game, files):
    """Expected index-0 stream: each MAME region's window, in map order."""
    regs = {r['tag']: r for r in game['regions']}
    out = bytearray()
    for name, rid, base, size, tag in PLATFORM_MAP:
        if len(out) != base:
            fail('map not contiguous at ' + name)
        reg = regs.get(tag)
        if reg is None:
            out += bytes(size)
            continue
        if region_extent(reg) > size:
            fail('%s: MAME data extends beyond the %s window' % (tag, name))
        img = mame_region(reg, files)
        win = img[:size]
        if len(win) < size:
            win += bytes([reg['fill']]) * (size - len(win))
        out += win
    if len(out) != STREAM_END:
        fail('stream length')
    return out

# ---------------------------------------------------------------------------
# Check record
def crc32(b):
    return binascii.crc32(b) & 0xFFFFFFFF

def check_entries(game, files=None):
    """Entries (region id, lanes, offset, length, [crcs]) covering every stream
    byte. File CRCs come from MAME metadata; fill CRCs are computed from the fill."""
    regs = {r['tag']: r for r in game['regions']}
    ents = []
    for name, rid, base, size, tag in PLATFORM_MAP:
        reg = regs.get(tag)
        fillb = reg['fill'] if reg else 0
        spans = []                                     # (offset, length, lanes, [crc])
        if reg:
            loads = sorted(reg['loads'], key=lambda l: l['offset'])
            i = 0
            while i < len(loads):
                ld = loads[i]
                k = ld['kind']
                if k == 'ROM_LOAD':
                    if ld['offset'] % 4 or ld['length'] % 4:
                        fail('%s: unaligned ROM_LOAD' % ld['name'])
                    spans.append((ld['offset'], ld['length'], 1, [int(ld['crc'], 16)]))
                    i += 1
                elif k in ('ROM_LOAD32_WORD', 'ROM_LOAD32_BYTE'):
                    lanes = 2 if k == 'ROM_LOAD32_WORD' else 4
                    grp = loads[i:i+lanes]
                    o = ld['offset']
                    if o % 4 or [g['offset'] for g in grp] != [o + j*(4//lanes) for j in range(lanes)] \
                       or any(g['kind'] != k or g['length'] != ld['length'] for g in grp):
                        fail('%s: incomplete %s group' % (ld['name'], k))
                    spans.append((o, ld['length'] * lanes, lanes, [int(g['crc'], 16) for g in grp]))
                    i += lanes
                else:
                    fail('unsupported load kind for check record: ' + k)
        # fill gaps with fill-CRC entries
        pos, full = 0, []
        for s in sorted(spans):
            if s[0] < pos:
                fail(name + ': overlapping loads')
            if s[0] > pos:
                full.append((pos, s[0] - pos, 1, [crc32(bytes([fillb]) * (s[0] - pos))]))
            full.append(s)
            pos = s[0] + s[1]
        if pos > size:
            fail(name + ': loads beyond window')
        if pos < size:
            full.append((pos, size - pos, 1, [crc32(bytes([fillb]) * (size - pos))]))
        for o, n, lanes, crcs in full:
            ents.append((rid, lanes, o, n, crcs))
    if len(ents) > MAX_ENTRIES:
        fail('too many check entries')
    return ents

def record_bytes(ents, stream_len):
    b = bytearray(b'NB1C' + bytes([1, len(ents), 0, 0]) + struct.pack('<I', stream_len))
    b += bytes(32 - len(b))
    for rid, lanes, o, n, crcs in ents:
        c = (crcs + [0, 0, 0, 0])[:4]
        b += bytes([rid, lanes, 0, 0]) + struct.pack('<IIIIII', o, n, *c) + bytes(4)
    return bytes(b)

def parse_record(b):
    if b[:4] != b'NB1C' or b[4] != 1:
        fail('check record header')
    n = b[5]
    (slen,) = struct.unpack_from('<I', b, 8)
    ents = []
    for i in range(n):
        e = b[32 + 32*i: 64 + 32*i]
        rid, lanes = e[0], e[1]
        o, ln, c0, c1, c2, c3 = struct.unpack_from('<IIIIII', e, 4)
        ents.append((rid, lanes, o, ln, [c0, c1, c2, c3][:lanes]))
    return slen, ents

def entry_crcs(stream, base, o, n, lanes):
    """What nb1_rom_check computes: lane of byte k in a longword = k*lanes/4."""
    lanebufs = [bytearray() for _ in range(lanes)]
    seg = stream[base + o: base + o + n]
    if lanes == 1:
        return [crc32(seg)]
    per = 4 // lanes
    for j in range(lanes):
        lanebufs[j] = b''.join(seg[i + j*per: i + j*per + per] for i in range(0, n, 4))
    return [crc32(x) for x in lanebufs]

# ---------------------------------------------------------------------------
# generate
def hexlines(b, indent):
    out = []
    for i in range(0, len(b), 32):
        out.append(indent + ' '.join('%02X' % x for x in b[i:i+32]))
    return '\n'.join(out)

def mra_zips(game):
    # clone sets (MAME split/merged): the clone's own zip, then the parent's, then the C75 BIOS device
    names = [game['set']] + ([game['parent']] if game.get('parent') else []) + ['namcoc75']
    return '|'.join(n + '.zip' for n in names)

def cmd_generate(a):
    game = json.load(open(a.game))
    regs = {r['tag']: r for r in game['regions']}
    ents = check_entries(game)
    rec = record_bytes(ents, STREAM_END)
    zips = mra_zips(game)
    L = []
    L.append('<!--')
    L.append('  %s - Namco NB-1 - MRA for the %s MiSTer core.' % (game['description'], RBF))
    L.append('')
    L.append('  GENERATED by scripts/mra/nb1_mra.py from scripts/mra/games/%s.json' % game['set'])
    L.append('  (MAME %s metadata). Do not edit by hand; regenerate and run' % game['mame']['version'])
    L.append('  `nb1_mra.py validate`. No ROM data is embedded in this file.')
    L.append('')
    L.append('  Loads the ROM set, the board record (index 2: which KEYCUS part is fitted),')
    L.append('  a check record (index 3) that the core uses to verify every region after')
    L.append('  loading, and the EEPROM (index 1: power-on image + MiSTer NVRAM')
    L.append('  save/restore). The C75 BIOS (c75.bin) comes from the game zip (non-merged')
    L.append('  sets) or from namcoc75.zip (split/merged sets).')
    L.append('')
    L.append('  ioctl index 0 = the NB-1 platform ROM stream (docs/MRA_FORMAT.md):')
    L.append('  every MAME region in MAME byte order, padded to its fixed window, in')
    L.append('  platform order; stream offset == SDRAM byte address. The same layout serves')
    L.append('  every NB-1 game; nothing in the RBF knows which game is loaded.')
    L.append('-->')
    L.append('<misterromdescription>')
    L.append('    <name>%s</name>' % game['description'])
    L.append('    <setname>%s</setname>' % game['set'])
    L.append('    <rbf>%s</rbf>' % RBF)
    L.append('    <mameversion>%s</mameversion>' % re.sub(r'\D', '', game['mame']['version'])[:4].rjust(4, '0'))
    L.append('    <year>%s</year>' % game['year'])
    L.append('    <manufacturer>%s</manufacturer>' % game['manufacturer'])
    L.append('    <platform>Namco NB-1</platform>')
    if game.get('rotate') in (90, 270):
        L.append('    <rotation>vertical (%s)</rotation>' % ('cw' if game['rotate'] == 90 else 'ccw'))
    # M14: pad functions in the core's CONF_STR J1 order (MAME namconb1 ports: 3 buttons, start,
    # coin, service); a game entry may rename them ("buttons": "Shot,Bomb,-,Start,Coin,Service")
    L.append('    <buttons names="%s" default="A,B,X,Start,Select,R"/>'
             % game.get('buttons', 'Button 1,Button 2,Button 3,Start,Coin,Service'))
    L.append('')
    L.append('    <!-- M2 check record: header + %d entries (region, lanes, offset, length,' % len(ents))
    L.append('         CRC32 per lane). Lane CRCs equal MAME\'s per-file CRC32s; gap entries')
    L.append('         carry the CRC of the fill. Sent first so it is present when the ROM')
    L.append('         stream completes. -->')
    L.append('    <rom index="%d">' % IOCTL_CHECK)
    L.append('        <part>')
    L.append(hexlines(rec, '            '))
    L.append('        </part>')
    L.append('    </rom>')
    L.append('')
    kc = game['board']['keycus']
    L.append('    <!-- M7 board record (NB1B v1, 16 bytes): KEYCUS mode %d, ID $%04X (%s)' % (
        kc['mode'], kc['id'], kc['part'] or 'none'))
    L.append('         on word %d, changing value on word %d. From MAME %s.' % (
        kc['id_word'], kc['rnd_word'], kc['source']))
    L.append('         Format: rtl/nb1/nb1_board_config.sv. -->')
    L.append('    <rom index="%d">' % IOCTL_BOARD)
    L.append('        <part>')
    L.append(hexlines(board_bytes(game), '            '))
    L.append('        </part>')
    L.append('    </rom>')
    L.append('')
    L.append('    <!-- M18 EEPROM (28C16, 2 KiB, MAME EEPROM_2816): index %d carries the power-on' % IOCTL_NVRAM)
    L.append('         image, then MiSTer replaces it with the saved .nvm if one exists and saves')
    L.append('         it again after the game writes the EEPROM. Both come before the ROM stream,')
    L.append('         so the CPU never runs before the EEPROM holds its final contents. File')
    L.append('         format = MAME nvram/<set>/eeprom (cell 0 first). Core: rtl/nb1/nb1_nvram.sv. -->')
    eep = regs.get('eeprom')
    if eep:   # MAME default image (e.g. gun calibration sets): nvram_default loads the "eeprom" region
        ld = eep['loads'][0]
        if len(eep['loads']) != 1 or ld['length'] != NVRAM_BYTES or ld['offset'] != 0:
            fail('unsupported "eeprom" region layout')
        L.append('    <rom index="%d" zip="%s" md5="none">' % (IOCTL_NVRAM, zips))
        L.append('        <part name="%s" crc="%s"/>' % (ld['name'], ld['crc']))
        L.append('    </rom>')
    else:     # no "eeprom" region: MAME nvram_default = erased ($FF)
        L.append('    <rom index="%d">' % IOCTL_NVRAM)
        L.append('        <part repeat="0x%X">FF</part>' % NVRAM_BYTES)
        L.append('    </rom>')
    L.append('    <nvram index="%d" size="%d"/>' % (IOCTL_NVRAM, NVRAM_BYTES))
    L.append('')
    L.append('    <rom index="%d" zip="%s" md5="none">' % (IOCTL_ROM, zips))
    for name, rid, base, size, tag in PLATFORM_MAP:
        reg = regs.get(tag)
        L.append('        <!-- %s: stream 0x%07X-0x%07X, MAME region "%s" -->' % (name, base, base + size - 1, tag))
        pos = 0
        loads = sorted(reg['loads'], key=lambda l: l['offset']) if reg else []
        fillb = reg['fill'] if reg else 0
        i = 0
        while i < len(loads):
            ld = loads[i]
            k = ld['kind']
            start = ld['offset'] & ~3 if k != 'ROM_LOAD' else ld['offset']
            if start > pos:
                L.append('        <part repeat="0x%X">%02X</part>' % (start - pos, fillb))
                pos = start
            if k == 'ROM_LOAD':
                L.append('        <part name="%s" crc="%s"/>' % (ld['name'], ld['crc']))
                pos += ld['length']
                i += 1
            elif k == 'ROM_LOAD32_WORD':
                a0, a1 = loads[i], loads[i+1]
                L.append('        <!-- ROM_LOAD32_WORD: %s -> bytes 0-1, %s -> bytes 2-3 of each longword -->'
                         % (a0['name'], a1['name']))
                L.append('        <interleave output="32">')
                L.append('            <part name="%s" crc="%s" map="0021"/>' % (a0['name'], a0['crc']))
                L.append('            <part name="%s" crc="%s" map="2100"/>' % (a1['name'], a1['crc']))
                L.append('        </interleave>')
                pos += 2 * ld['length']
                i += 2
            elif k == 'ROM_LOAD32_BYTE':
                grp = loads[i:i+4]
                L.append('        <interleave output="32">')
                for j, g in enumerate(grp):
                    m = ['0'] * 4
                    m[3 - j] = '1'
                    L.append('            <part name="%s" crc="%s" map="%s"/>' % (g['name'], g['crc'], ''.join(m)))
                L.append('        </interleave>')
                pos += 4 * ld['length']
                i += 4
            else:
                fail('unsupported load kind ' + k)
        if pos < size:
            L.append('        <part repeat="0x%X">%02X</part>' % (size - pos, fillb))
    L.append('    </rom>')
    L.append('</misterromdescription>')
    with open(a.out, 'w', newline='\n', encoding='utf-8') as f:
        f.write('\n'.join(L) + '\n')
    print('wrote', a.out, '(%d check entries)' % len(ents))

# ---------------------------------------------------------------------------
# MiSTer mra_loader.cpp emulation (Main_MiSTer support/arcade/mra_loader.cpp:
# rom_data(), interleave start/end, <part repeat>, hex parts).
class MisterRom:
    def __init__(self):
        self.data = bytearray()
        self.romlen = [0] * 8
        self.unitlen = 1

    def _ensure(self, n):
        if len(self.data) < n:
            self.data += bytes(n - len(self.data))

    def rom_data(self, buf, imap):
        m = imap or 1
        idx, mr = 0, m
        for _ in range(self.unitlen):
            if mr & 0xF:
                break
            mr >>= 4
            idx += 1
        if idx >= self.unitlen:
            fail('illegal map')
        offsets, first, gaps, mr = [], True, 0, m
        for _ in range(self.unitlen):
            if mr & 0xF:
                offsets.append(idx + (mr & 0xF) - 1 + gaps)
                first = False
            elif not first:
                gaps += 1
            mr >>= 4
        p = 0
        chunk = len(buf)
        while chunk:
            self._ensure(self.romlen[idx] + self.unitlen)
            for off in offsets:
                self.data[self.romlen[idx] + off] = buf[p]
                p += 1
                chunk -= 1
            self.romlen[idx] += self.unitlen

def mister_stream(mra_path, rom_index, files):
    root = ET.parse(mra_path).getroot()
    roms = [r for r in root.findall('rom') if int(r.get('index', '0')) == rom_index]
    if len(roms) != 1:
        fail('expected one <rom index=%d>' % rom_index)
    st = MisterRom()

    def part(p, imap):
        rep = int(p.get('repeat', '1'), 0)
        if p.get('name'):
            if p.get('offset') or p.get('length'):
                fail('part offset/length not used by NB-1 MRAs')
            d = files[p.get('name')]
            for _ in range(rep):
                st.rom_data(d, imap)
        else:
            d = bytes.fromhex(''.join((p.text or '').split()))
            for _ in range(rep):
                st.rom_data(d, imap)

    for node in roms[0]:
        if node.tag == 'part':
            st.unitlen = 1
            part(node, int(node.get('map', '0'), 16))
        elif node.tag == 'interleave':
            if int(node.get('input', '8')) != 8:
                fail('interleave input must be 8')
            out = int(node.get('output'))
            st.unitlen = out // 8
            for i in range(1, 8):
                st.romlen[i] = st.romlen[0]
            for p in node.findall('part'):
                part(p, int(p.get('map', '0'), 16))
            st.unitlen = 1
        elif node.tag is ET.Comment:
            pass
    return bytes(st.data[:st.romlen[0]]), roms[0]

# ---------------------------------------------------------------------------
# validate
def synthetic_files(game):
    files = {}
    for reg in game['regions']:
        for ld in reg['loads']:
            seed = hashlib.sha256(ld['name'].encode()).digest()
            n = ld['length']
            blk = bytearray()
            ctr = 0
            while len(blk) < n:
                blk += hashlib.sha256(seed + ctr.to_bytes(8, 'little')).digest()
                ctr += 1
            files[ld['name']] = bytes(blk[:n])
    return files

def pkg_map():
    src = open(os.path.join(REPO, 'rtl', 'nb1', 'nb1_mem_pkg.sv')).read()
    base = dict(re.findall(r"REG_(\w+):\s*region_base\s*=\s*25'h([0-9A-Fa-f]+);", src))
    size = dict(re.findall(r"REG_(\w+):\s*region_size\s*=\s*26'h([0-9A-Fa-f]+);", src))
    ids = dict(re.findall(r"localparam logic \[3:0\] REG_(\w+)\s*=\s*4'd(\d+);", src))
    end = re.search(r"STREAM_END\s*=\s*25'h([0-9A-Fa-f]+)", src).group(1)
    return {k: (int(ids[k]), int(base[k], 16), int(size[k], 16)) for k in ids}, int(end, 16)

def cmd_validate(a):
    game = json.load(open(a.game))
    checks = 0
    # 1. platform map == RTL package
    pm, pend = pkg_map()
    for name, rid, base, size, tag in PLATFORM_MAP:
        if pm.get(name) != (rid, base, size):
            fail('map entry %s differs from nb1_mem_pkg.sv: %s' % (name, pm.get(name)))
        checks += 1
    if pend != STREAM_END or len(pm) != len(PLATFORM_MAP):
        fail('STREAM_END / region count differs from nb1_mem_pkg.sv')
    # 2. optional: metadata == -listxml
    if a.listxml:
        root = ET.parse(a.listxml).getroot()
        mach = {m.get('name'): m for m in root.iter('machine')}
        known = {}
        for m in (game['set'], 'namcoc75'):
            for r in mach[m].findall('rom'):
                known[r.get('name')] = (int(r.get('size')), r.get('crc'), r.get('sha1'))
        for reg in game['regions']:
            for ld in reg['loads']:
                if known.get(ld['name']) != (ld['length'], ld['crc'], ld['sha1']):
                    fail('JSON metadata differs from listxml for ' + ld['name'])
                checks += 1
        print('  metadata matches -listxml (%d files)' % sum(len(r['loads']) for r in game['regions']))
    # 3. MRA parts == metadata
    root = ET.parse(a.mra).getroot()
    if root.findtext('rbf') != RBF or root.findtext('setname') != game['set']:
        fail('rbf/setname')
    meta = {ld['name']: ld for r in game['regions'] for ld in r['loads']}
    rom0 = [r for r in root.findall('rom') if r.get('index') == str(IOCTL_ROM)][0]
    used = set()
    for p in rom0.iter('part'):
        if p.get('name'):
            ld = meta.get(p.get('name'))
            if ld is None or p.get('crc') != ld['crc']:
                fail('MRA part %s not in MAME metadata / wrong CRC' % p.get('name'))
            used.add(p.get('name'))
    if used != set(meta):
        fail('MRA does not load exactly the MAME files: missing %s' % sorted(set(meta) - used))
    checks += len(used)
    # 4. MiSTer-emulated stream == MAME region assembly (synthetic contents)
    syn = synthetic_files(game)
    got, _ = mister_stream(a.mra, IOCTL_ROM, syn)
    exp = platform_stream(game, syn)
    if len(got) != len(exp):
        fail('stream length %X, expected %X' % (len(got), len(exp)))
    if got != exp:
        i = next(i for i in range(len(exp)) if got[i] != exp[i])
        fail('stream differs from MAME layout at 0x%X' % i)
    checks += 1
    print('  MiSTer-emulated index-0 stream == MAME region layout in the NB-1 map (0x%X bytes)' % len(got))
    # region boundaries: every byte of every region comes from that region
    for name, rid, base, size, tag in PLATFORM_MAP:
        if got[base:base+size] != exp[base:base+size]:
            fail(name)
        checks += 1
    # 5. check record
    recb, _ = mister_stream(a.mra, IOCTL_CHECK, {})
    slen, ents = parse_record(recb)
    if slen != STREAM_END:
        fail('record stream length')
    if ents != [(r, l, o, n, c) for r, l, o, n, c in check_entries(game)]:
        fail('check record differs from the entries derived from MAME metadata')
    idmap = {rid: (name, base, size) for name, rid, base, size, tag in PLATFORM_MAP}
    cover = {rid: [] for rid in idmap}
    for rid, lanes, o, n, crcs in ents:
        cover[rid].append((o, n))
        if lanes not in (1, 2, 4) or o % 4 or n % 4:
            fail('entry shape')
        # entry CRCs on the synthetic image must equal the synthetic files' CRCs
        if entry_crcs(exp, idmap[rid][1], o, n, lanes) != [
                c for c in entry_crcs_synthetic(game, syn, rid, o, n, lanes)]:
            fail('entry lane assignment')
    for rid, spans in cover.items():
        pos = 0
        for o, n in sorted(spans):
            if o != pos:
                fail('check record gap/overlap in %s at 0x%X' % (idmap[rid][0], pos))
            pos = o + n
        if pos != idmap[rid][2]:
            fail('check record does not cover all of ' + idmap[rid][0])
        checks += 1
    print('  check record: %d entries, cover every stream byte exactly once, CRCs = MAME file CRCs / fill CRCs' % len(ents))
    # 5a. board record (M7)
    brd, _ = mister_stream(a.mra, IOCTL_BOARD, {})
    if brd != board_bytes(game):
        fail('board record differs from the JSON board description')
    kc = game['board']['keycus']
    if a.mame_src:
        ref = keycus_from_source(open(a.mame_src, encoding='utf-8').read(), game['set'])
        if any(ref[k] != kc[k] for k in ('mode', 'id', 'id_word', 'rnd_word', 'part')):
            fail('JSON KEYCUS description differs from MAME custom_key_r: %r' % ref)
        checks += 1
    checks += 1
    print('  board record v2: orientation ROT%d; KEYCUS mode %d, ID $%04X (%s) on word %d, changing word %d%s' % (game.get('rotate', 0),
        kc['mode'], kc['id'], kc['part'] or 'none', kc['id_word'], kc['rnd_word'],
        ' (= MAME custom_key_r)' if a.mame_src else ''))
    # 5b. EEPROM image + NVRAM (M18)
    kids = list(root)
    nv = root.findall('nvram')
    if len(nv) != 1 or nv[0].get('index') != str(IOCTL_NVRAM) or int(nv[0].get('size'), 0) != NVRAM_BYTES:
        fail('<nvram index="%d" size="%d"/> missing or wrong' % (IOCTL_NVRAM, NVRAM_BYTES))
    idx = [r.get('index') for r in root.findall('rom')]
    if sorted(idx) != sorted(str(i) for i in (IOCTL_ROM, IOCTL_NVRAM, IOCTL_BOARD, IOCTL_CHECK)):
        fail('rom indices must be exactly 0, 1, 2, 3 once each: %r' % idx)
    rom1 = [r for r in root.findall('rom') if r.get('index') == str(IOCTL_NVRAM)][0]
    if not (kids.index(rom1) < kids.index(nv[0]) < kids.index(rom0)):
        fail('order must be: EEPROM image, <nvram>, then the ROM stream')
    eimg, _ = mister_stream(a.mra, IOCTL_NVRAM, {})
    if 'eeprom' not in {r['tag'] for r in game['regions']} and eimg != bytes([0xFF]) * NVRAM_BYTES:
        fail('EEPROM power-on image is not %d x $FF' % NVRAM_BYTES)
    checks += 3
    print('  EEPROM: index %d power-on image %d bytes (erased), <nvram index="%d" size="%d"/>, both before the ROM stream'
          % (IOCTL_NVRAM, len(eimg), IOCTL_NVRAM, NVRAM_BYTES))
    # 6. optional: the owner's local ROM set
    if a.zip:
        # --zip may list several zips separated by '|' (clone, parent, C75 BIOS), searched in order
        files = {}
        zs = [zipfile.ZipFile(zp) for zp in a.zip.split('|')]
        for name, ld in meta.items():
            info = None
            for z in zs:
                infos = z.infolist()
                info = {'%08x' % i.CRC: i for i in infos}.get(ld['crc']) or {i.filename: i for i in infos}.get(name)
                if info is not None:
                    break
            if info is None:
                fail('%s not in %s' % (name, a.zip))
            d = z.read(info)
            if len(d) != ld['length'] or '%08x' % crc32(d) != ld['crc'] or hashlib.sha1(d).hexdigest() != ld['sha1']:
                fail('%s: size/CRC/SHA1 mismatch in the zip' % name)
            files[name] = d
        real, _ = mister_stream(a.mra, IOCTL_ROM, files)
        if real != platform_stream(game, files):
            fail('real stream differs from MAME layout')
        for rid, lanes, o, n, crcs in ents:
            if entry_crcs(real, idmap[rid][1], o, n, lanes) != crcs:
                fail('check entry %s+0x%X fails on the real ROM set' % (idmap[rid][0], o))
        p = idmap[0][1]
        ssp, pc = struct.unpack_from('>II', real, p)
        print('  local ROM set: all %d files match MAME SHA1; all %d check entries pass on the real stream'
              % (len(files), len(ents)))
        print('  spot check: PROG longword 0 (SSP) = $%08X, longword 4 (PC) = $%08X' % (ssp, pc))
        if (ssp, pc) != (0x001C0400, 0x00000400) and not a.any_vectors:
            fail('reset vectors differ from the documented values (NB1_HARDWARE_SPEC section 3)')
        print('  real stream CRC32 = %08X (not stored anywhere)' % crc32(real))
        checks += len(ents) + 1
    print('PASS MRA VALIDATION: %s, %d checks' % (os.path.basename(a.mra), checks))

def entry_crcs_synthetic(game, syn, rid, o, n, lanes):
    """Independent route: CRC of the source file slices that MAME places there."""
    regs = {r['tag']: r for r in game['regions']}
    tag = [t for nm, r, b, s, t in PLATFORM_MAP if r == rid][0]
    reg = regs.get(tag)
    for ld in (reg['loads'] if reg else []):
        k = ld['kind']
        span = ld['length'] * {'ROM_LOAD': 1, 'ROM_LOAD32_WORD': 2, 'ROM_LOAD32_BYTE': 4}[k]
        start = ld['offset'] & (~3 if k != 'ROM_LOAD' else ~0)
        if start == o and span == n:
            grp = [l for l in reg['loads'] if (l['offset'] & ~3) == o and l['kind'] == k]
            grp.sort(key=lambda l: l['offset'])
            return [crc32(syn[g['name']]) for g in grp][:lanes]
    fillb = reg['fill'] if reg else 0
    return [crc32(bytes([fillb]) * n)]

# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sp = ap.add_subparsers(dest='cmd', required=True)
    e = sp.add_parser('extract')
    e.add_argument('--mame-src', required=True)
    e.add_argument('--listxml', required=True)
    e.add_argument('--set', required=True)
    e.add_argument('--note')
    e.add_argument('-o', '--out', required=True)
    g = sp.add_parser('generate')
    g.add_argument('--game', required=True)
    g.add_argument('-o', '--out', required=True)
    v = sp.add_parser('validate')
    v.add_argument('--mra', required=True)
    v.add_argument('--game', required=True)
    v.add_argument('--listxml')
    v.add_argument('--zip', help="the local ROM set; several zips separated by '|' (clone|parent|namcoc75)")
    v.add_argument('--any-vectors', action='store_true', help='skip the NR2 reset-vector spot check (other program ROMs)')
    v.add_argument('--mame-src')
    k = sp.add_parser('keycus')
    k.add_argument('--mame-src', required=True)
    a = ap.parse_args()
    {'extract': cmd_extract, 'generate': cmd_generate, 'validate': cmd_validate,
     'keycus': cmd_keycus}[a.cmd](a)

if __name__ == '__main__':
    main()
