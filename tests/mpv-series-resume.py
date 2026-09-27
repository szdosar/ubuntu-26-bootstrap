"""Headless playback regression checks; uses only temporary media/resume data.

Run: python3 tests/mpv-series-resume.py (requires mpv and ffmpeg).
"""
import hashlib
import json
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

SCRIPT = Path(__file__).resolve().parents[1] / 'mpv/series-resume.lua'


def play(paths, state, resume=True, extra=()):
    with tempfile.TemporaryDirectory(prefix='mpv-series-ipc-') as runtime:
        endpoint = Path(runtime) / 'socket'
        args = ['mpv', '--no-config', '--load-scripts=no', f'--script={SCRIPT}',
                '--autocreate-playlist=no', '--vo=null', '--ao=null', '--pause',
                '--save-position-on-quit=no', f'--watch-later-dir={state}',
                f'--resume-playback={"yes" if resume else "no"}',
                f'--input-ipc-server={endpoint}', *extra, *map(str, paths)]
        proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if endpoint.exists():
                    break
                if proc.poll() is not None:
                    raise AssertionError(proc.stderr.read().decode())
                time.sleep(.05)
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(5)
                sock.connect(str(endpoint))
                stream = sock.makefile('r')
                request_id = 0

                def command(*cmd):
                    nonlocal request_id
                    request_id += 1
                    sock.sendall((json.dumps({'command': cmd, 'request_id': request_id}) + '\n').encode())
                    while True:
                        response = json.loads(stream.readline())
                        if response.get('request_id') == request_id:
                            return response.get('data')

                for _ in range(100):
                    if command('get_property', 'time-pos') is not None:
                        break
                    time.sleep(.05)
                else:
                    raise AssertionError('Playback did not initialize')
                time.sleep(.15)
                result = (command('get_property', 'filename'),
                          command('get_property', 'time-pos'),
                          [Path(p['filename']).name for p in command('get_property', 'playlist')])
                command('quit')
                proc.wait(timeout=5)
            errors = proc.stderr.read().decode()
            assert 'Lua error' not in errors, errors
            return result
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()


with tempfile.TemporaryDirectory(prefix='mpv-series-regression-') as runtime:
    root = Path(runtime)
    media, state = root / 'media', root / 'state'
    media.mkdir()
    state.mkdir()
    seed = root / 'seed.mkv'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=s=32x32:r=1',
                    '-t', '40', '-c:v', 'libx264', str(seed)], check=True)
    heat = 'Heat.1995.1080p.MA.WEBRip.DDP5.1.x264-ZoroSenpai.mkv'
    enemy = '[国家公敌]Enemy.of.the.State.1998.Blu-ray.1080p.x265.LPCM.5.1-CarPT.mkv'
    episodes = [f'[她的涅槃].Born.Again.2026.S01E{n:02}.1080p.mkv' for n in (1, 2, 3, 10)]
    other = 'Different.Show.S01E03.mkv'
    season2 = '[她的涅槃].Born.Again.2026.S02E01.1080p.mkv'
    for name in [heat, enemy, *episodes, other, season2]:
        shutil.copyfile(seed, media / name)

    def save(name, position=20):
        key = hashlib.md5(str(media / name).encode()).hexdigest().upper()
        (state / key).write_text(f'start={position}\n')

    save(enemy)
    result = play([media / heat], state)
    assert result[0] == heat and result[2] == [heat], result
    print('PASS: movie does not open/resume a different movie')

    save(heat, 12)
    result = play([media / heat], state)
    assert result[0] == heat and abs(result[1] - 12) < 1, result
    print('PASS: the selected movie still resumes its own timestamp')

    result = play([media / episodes[1]], state)
    assert result[0] == episodes[1] and result[2] == episodes, result
    print('PASS: matching series/season only, numerical E02 before E10, clicked episode retained')

    save(episodes[2])
    save(other, 25)
    save(season2, 30)
    result = play([media / episodes[0]], state)
    assert result[0] == episodes[2] and abs(result[1] - 20) < 1 and result[2] == episodes, result
    print('PASS: same-series E03 resumes without crossing series or season')

    save(episodes[2])
    result = play([media / episodes[0]], state, resume=False)
    assert result[0] == episodes[0] and result[1] < 1, result
    print('PASS: resume-playback=no remains effective')

    result = play([media / heat, media / enemy], state, resume=False)
    assert result[2] == [heat, enemy], result
    print('PASS: explicit multi-file playlist preserved')
