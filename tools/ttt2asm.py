"""Convert TIATracker songs (.ttt) into one data set for the TIATracker player.

    python tools/ttt2asm.py OUT.inc SONG.ttt [SONG.ttt ...]

All songs share one player and one set of tables: their instruments, percussion
and patterns are merged and each song gets a start position in the sequence
table (SongC0/SongC1, indexed by song number = argument order).  A song that
ends without a goto gets a pause and a looping hold pattern appended so it
plays once and then stays silent.  Song number len(songs) is "silence".

Data format (see the player's comments in src/tt_player.asm and the TIATracker
manual): a note byte is instrument<<5 | frequency (instruments are numbered
from 1), 8 = hold, 16 = pause, 17+ = percussion, 0 = end of pattern.  A "pure
combined" instrument (waveform 16) becomes two player instruments, AUDC 4 for
notes 0-31 and AUDC 12 for notes 32-63.  Envelope bytes are (frequency+8)<<4 |
volume; percussion volume bytes are AUDC<<4 | volume.  Pattern speeds are
stored as frames-1.  Slides, overlay percussion and funk tempo are not used
by the game's player build and are rejected here.
"""
import json
import sys

HOLD, PAUSE, FIRST_PERC = 8, 16, 17


def main():
    out, paths = sys.argv[1], sys.argv[2:]
    songs = [json.load(open(p, encoding='utf-8')) for p in paths]

    ins_ctrl, ins_ad, ins_sus, ins_rel, ins_env = [], [], [], [], []   # player instruments
    perc_idx, perc_freq, perc_cv = [], [], []
    patterns = []                   # (bytes, speed)
    pattern_ids = {}                # bytes -> index (identical patterns are shared)
    seq = []                        # the sequence table
    seq_names = []
    starts = []                     # (c0 start, c1 start) per song

    def add_pattern(data, speed):
        key = (bytes(data), speed)
        if key not in pattern_ids:
            pattern_ids[key] = len(patterns)
            patterns.append(key)
        return pattern_ids[key]

    def add_instrument(ins, ctrl):
        """Player instrument number (1-based) for a .ttt instrument with AUDC ctrl."""
        n = ins['envelopeLength']
        f, v = ins['frequencies'][:n], ins['volumes'][:n]
        sus, rel = ins['sustainStart'], ins['releaseStart']
        assert 0 <= sus < rel <= n, 'bad envelope'
        env = [((fq + 8) << 4) | vol for fq, vol in zip(f, v)]
        assert all(-8 <= fq <= 7 and 0 <= vol <= 15 for fq, vol in zip(f, v))
        assert 0 not in env[:rel], 'an envelope byte of 0 (freq -8, vol 0) would end the envelope'
        base = len(ins_env)
        ins_env.extend(env[:rel] + [0xFF] + env[rel:] + [0])    # junk byte before the release, 0 ends it
        key = (ctrl, tuple(ins_env[base:]))
        for i, k in enumerate(zip(ins_ctrl, ins_ad)):
            if (k[0], tuple(ins_env[k[1]:k[1] + len(ins_env) - base])) == key:
                del ins_env[base:]
                return i + 1
        ins_ctrl.append(ctrl)
        ins_ad.append(base)
        ins_sus.append(base + sus)
        ins_rel.append(base + rel)          # index of the junk byte (the player adds 1)
        assert len(ins_ctrl) <= 7, 'more than 7 instruments'
        return len(ins_ctrl)

    def add_percussion(pc):
        n = pc['envelopeLength']
        assert not pc['overlay'], 'overlay percussion is not supported'
        freq, cv = pc['frequencies'][:n], [(w << 4) | v for w, v in zip(pc['waveforms'][:n], pc['volumes'][:n])]
        assert 0 not in cv, 'a percussion byte of 0 would end the envelope early'
        key = (tuple(freq), tuple(cv))
        for i, start in enumerate(perc_idx):
            if (tuple(perc_freq[start - 1:start - 1 + n]), tuple(perc_cv[start - 1:start - 1 + n])) == key \
                    and perc_cv[start - 1 + n] == 0:
                return i + 1
        perc_idx.append(len(perc_freq) + 1)  # stored +1
        perc_freq.extend(freq + [0])
        perc_cv.extend(cv + [0])
        assert len(perc_idx) <= 15, 'more than 15 percussion instruments'
        return len(perc_idx)

    hold_pat = add_pattern([HOLD, 0], 1)
    pause_pat = add_pattern([PAUSE, 0], 1)

    for path, song in zip(paths, songs):
        name = song.get('metaName') or path
        assert song['evenspeed'] == song['oddspeed'], f'{name}: funk tempo is not supported'
        ins_map, perc_map = {}, {}
        local = {}      # .ttt pattern index -> player pattern index

        def conv_pattern(pi):
            if pi in local:
                return local[pi]
            pat = song['patterns'][pi]
            speed = song['evenspeed'] if song['globalspeed'] else pat['evenspeed']
            if not song['globalspeed']:
                assert pat['evenspeed'] == pat['oddspeed'], f'{name}: funk tempo is not supported'
            data = []
            for note in pat['notes']:
                t, val, num = note['type'], note['value'], note['number']
                if t == 0:
                    data.append(HOLD)
                elif t == 2:
                    data.append(PAUSE)
                elif t == 1:
                    ins = song['instruments'][num]
                    wave = ins['waveform']
                    if wave == 16:                       # pure combined
                        ctrl, val = (12, val - 32) if val >= 32 else (4, val)
                    else:
                        ctrl = wave
                    assert 0 <= val <= 31, f'{name}: note value {val} out of range'
                    key = (num, ctrl)
                    if key not in ins_map:
                        ins_map[key] = add_instrument(ins, ctrl)
                    data.append((ins_map[key] << 5) | val)
                elif t == 3:
                    if num not in perc_map:
                        perc_map[num] = add_percussion(song['percussion'][num])
                    data.append(FIRST_PERC + perc_map[num] - 1)
                else:
                    raise SystemExit(f'{name}: slides are not supported')
            assert len(data) <= 64
            data.append(0)
            local[pi] = add_pattern(data, speed)
            return local[pi]

        song_start = []
        for ch, chan in enumerate(song['channels']):
            base = len(seq)
            song_start.append(base)
            entries = chan['sequence']
            for e in entries:
                seq.append(conv_pattern(e['patternindex']))
                seq_names.append(f'{name} ch{ch}')
                if e['gototarget'] >= 0:
                    assert e is entries[-1], f'{name}: a goto must be the last entry'
                    seq.append(0x80 | (base + e['gototarget']))
                    seq_names.append(f'goto {base + e["gototarget"]}')
            if entries[-1]['gototarget'] < 0:         # plays once, then silence
                seq.extend([pause_pat, hold_pat, 0x80 | (len(seq) + 1)])
                seq_names.extend([f'{name} ch{ch}: pause', 'hold', 'goto (hold forever)'])
        starts.append(tuple(song_start))

    # song len(songs): silence
    base = len(seq)
    seq.extend([pause_pat, hold_pat, 0x80 | (base + 1)]); seq_names.extend(['silence: pause', 'hold', 'goto'])
    seq.extend([pause_pat, hold_pat, 0x80 | (base + 4)]); seq_names.extend(['silence ch1: pause', 'hold', 'goto'])
    starts.append((base, base + 3))
    assert len(seq) < 128, 'sequence table too long for goto'

    def table(label, values, comment='', per=16):
        lines = [f'{label}' + (f'    ; {comment}' if comment else '')]
        for i in range(0, len(values), per):
            lines.append('        .byte ' + ','.join(str(v) for v in values[i:i + per]))
        return '\n'.join(lines) + '\n'

    o = ['; Generated by tools/ttt2asm.py from: ' + ', '.join(paths),
         '; Songs: ' + ', '.join(f'{i} = {s.get("metaName") or p}' for i, (p, s) in enumerate(zip(paths, songs)))
         + f', {len(songs)} = silence',
         '; Data for the TIATracker player (src/tt_player.asm); see the tool for the format.', '',
         'TT_GLOBAL_SPEED         = 0', 'TT_USE_OVERLAY          = 0', 'TT_USE_SLIDE            = 0',
         'TT_USE_GOTO             = 1', 'TT_USE_FUNKTEMPO        = 0', 'TT_STARTS_WITH_NOTES    = 0', '',
         'TT_FREQ_MASK    = %00011111', 'TT_INS_HOLD     = 8', 'TT_INS_PAUSE    = 16', 'TT_FIRST_PERC   = 17', '',
         'tt_TrackDataStart',
         table('tt_InsCtrlTable', ins_ctrl, 'AUDC per instrument'),
         table('tt_InsADIndexes', ins_ad, 'envelope start'),
         table('tt_InsSustainIndexes', ins_sus, 'sustain start'),
         table('tt_InsReleaseIndexes', ins_rel, 'release start - 1'),
         table('tt_InsFreqVolTable', ins_env, '(freq+8)<<4 | volume; 0 = end'),
         table('tt_PercIndexes', perc_idx, 'first frame + 1'),
         table('tt_PercFreqTable', perc_freq, 'AUDF'),
         table('tt_PercCtrlVolTable', perc_cv, 'AUDC<<4 | volume; 0 = end'),
         ]
    for i, (data, speed) in enumerate(patterns):
        o.append(table(f'tt_Pattern{i}', list(data), f'{len(data) - 1} rows, {speed} frames per row'))
    o.append(table('tt_PatternSpeeds', [sp - 1 for _, sp in patterns], 'frames per row - 1'))
    o.append(table('tt_PatternPtrLo', [f'<tt_Pattern{i}' for i in range(len(patterns))], per=8))
    o.append(table('tt_PatternPtrHi', [f'>tt_Pattern{i}' for i in range(len(patterns))], per=8))
    o.append('tt_SequenceTable    ; pattern numbers; $80 | n = goto entry n')
    for i, (v, n) in enumerate(zip(seq, seq_names)):
        o.append(f'        .byte ${v:02X}        ; {i:3d}  {n}')
    o.append('')
    o.append(table('SongC0', [s[0] for s in starts], 'sequence start per song, channel 0'))
    o.append(table('SongC1', [s[1] for s in starts], 'channel 1'))
    o.append('        echo "Track data:", (* - tt_TrackDataStart)d, "bytes"\n')
    open(out, 'w', encoding='utf-8', newline='\n').write('\n'.join(o))
    print(f'{out}: {len(ins_ctrl)} instruments, {len(perc_idx)} percussion, {len(patterns)} patterns, '
          f'{len(seq)} sequence entries; songs start at {starts}')


main()
