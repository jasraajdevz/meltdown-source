import json, os, re, subprocess, sys
ok, bad, warn = [], [], []
def chk(c, msg, w=False):
    (ok if c else (warn if w else bad)).append(msg)

def read(p):
    try: return open(p).read()
    except Exception: return ''

# --- identity -------------------------------------------------------------
g = read('android/app/build.gradle.kts')
ios = read('ios/Runner.xcodeproj/project.pbxproj')
ns = re.search(r'namespace = "([^"]+)"', g)
appid = re.search(r'applicationId = "([^"]+)"', g)
bid = re.search(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;\s]+)', ios)
kt = [os.path.join(r,f) for r,_,fs in os.walk('android/app/src/main/kotlin') for f in fs if f.endswith('.kt')]
ktpkg = re.search(r'package ([\w.]+)', read(kt[0])) if kt else None
ids = {ns.group(1) if ns else None, appid.group(1) if appid else None, bid.group(1) if bid else None}
chk(len(ids)==1 and None not in ids, f'bundle id identical on both platforms: {ids.pop() if len(ids)==1 else ids}')
chk(ktpkg and appid and ktpkg.group(1)==appid.group(1), f'kotlin package matches applicationId ({ktpkg.group(1) if ktpkg else "?"})')

am = read('android/app/src/main/AndroidManifest.xml')
plist = read('ios/Runner/Info.plist')
chk('android:label="MELTDOWN"' in am, 'android display name is MELTDOWN')
chk('<string>MELTDOWN</string>' in plist, 'ios display name is MELTDOWN')

# --- orientation ----------------------------------------------------------
chk('android:screenOrientation="portrait"' in am, 'android locked to portrait')
chk('LandscapeLeft' not in plist, 'ios locked to portrait (incl. iPad)')

# --- launch ---------------------------------------------------------------
lb = read('android/app/src/main/res/drawable/launch_background.xml')
st = read('android/app/src/main/res/values/styles.xml')
sb = read('ios/Runner/Base.lproj/LaunchScreen.storyboard')
chk('@android:color/white' not in lb and 'splash_background' in lb, 'android launch screen is not white')
chk('Theme.Black' in st, 'android launch theme is dark')
chk('red="1" green="1" blue="1"' not in sb, 'ios launch screen is not white')

# --- icons ----------------------------------------------------------------
def px(p):
    try:
        out = subprocess.run(['sips','-g','pixelWidth',p],capture_output=True,text=True).stdout
        return int(re.search(r'pixelWidth: (\d+)', out).group(1))
    except Exception: return 0

appicon = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
c = json.loads(read(f'{appicon}/Contents.json'))
missing, wrong = [], []
for im in c['images']:
    fn = im.get('filename')
    if not fn: missing.append(im.get('size')); continue
    want = round(float(im['size'].split('x')[0]) * int(im['scale'].rstrip('x')))
    got = px(f'{appicon}/{fn}')
    if got != want: wrong.append(f'{fn} {got}!={want}')
chk(not missing, f'every declared iOS icon slot has a file ({len(c["images"])} slots)')
chk(not wrong, f'every iOS icon is the right pixel size' + (f' — WRONG: {wrong}' if wrong else ''))
chk(px(f'{appicon}/Icon-App-1024x1024@1x.png')==1024, 'iOS 1024 marketing icon present (App Store requires it)')

dens = {'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}
bad_mip=[]
for d,w in dens.items():
    for n in ['ic_launcher','ic_launcher_round']:
        p=f'android/app/src/main/res/mipmap-{d}/{n}.png'
        if not os.path.exists(p) or px(p)!=w: bad_mip.append(f'{d}/{n}')
chk(not bad_mip, 'android launcher icons at all 5 densities, square + round' + (f' — BAD: {bad_mip}' if bad_mip else ''))
chk(os.path.exists('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml'), 'android adaptive icon declared')
chk('monochrome' in read('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml'), 'adaptive icon has a monochrome layer (themed icons)')

# --- web ------------------------------------------------------------------
idx = read('web/index.html'); man = read('web/manifest.json')
chk('apple-touch-icon' in idx, 'web: apple-touch-icon for iOS home screen')
chk('theme-color' in idx, 'web: theme-color set')
chk('SW-KILL' in idx, 'web: stale service workers evicted on load')
chk(px('web/favicon.png')==32, 'web favicon is 32px')
try:
    mj=json.loads(man); chk(len(mj.get('icons',[]))>=4, f'web manifest declares {len(mj.get("icons",[]))} icons')
    chk(mj.get('name') and mj.get('short_name') and mj.get('description'), 'web manifest has name/short_name/description')
except Exception as e: chk(False, f'web manifest parses ({e})')

# --- hygiene --------------------------------------------------------------
gi = read('.gitignore')
chk('local.properties' in gi, 'gitignore: machine-local SDK path excluded')
chk('*.jks' in gi or '*.keystore' in gi, 'gitignore: signing keys cannot be committed')
tracked = subprocess.run(['git','ls-files'],capture_output=True,text=True).stdout.split()
secrets=[f for f in tracked if f.endswith(('.jks','.keystore','.p12','.mobileprovision')) or 'key.properties' in f]
chk(not secrets, 'no signing material or secrets tracked in git' + (f' — FOUND: {secrets}' if secrets else ''))
chk(not any(f.startswith('build/') for f in tracked), 'no build output tracked')
# --- native audio ---------------------------------------------------------
aio = read('lib/audio_io.dart')
chk('MethodChannel' in aio and 'meltdown/audio' in aio,
    'native audio: dart renders PCM and sends it over a channel')
chk('MissingPluginException' in aio,
    'native audio: degrades to haptics if the host has no handler')
swift = read('ios/Runner/AppDelegate.swift')
chk('meltdown/audio' in swift and 'AVAudioEngine' in swift,
    'ios: audio channel handler registered')
kt = ''
for r,_,fs in os.walk('android/app/src/main/kotlin'):
    for f in fs:
        if f.endswith('.kt'): kt += read(os.path.join(r,f))
chk('meltdown/audio' in kt and 'AudioTrack' in kt,
    'android: audio channel handler registered')

ver = re.search(r'^version: (.+)$', read('pubspec.yaml'), re.M)
chk(ver is not None, f'pubspec version set ({ver.group(1) if ver else "MISSING"})')
chk('publish_to:' in read('pubspec.yaml'), 'pubspec marked not-for-pub-publish')

# --- code -----------------------------------------------------------------
src = read('lib/main.dart')
chk('debugPrint(' not in src and 'print(' not in re.sub(r'//.*','',src), 'no stray prints in shipped code', w=True)
chk(not os.path.exists('test/widget_test.dart'), 'scaffold placeholder test removed')

print('\n'.join('  PASS  '+m for m in ok))
if warn: print('\n'.join('  WARN  '+m for m in warn))
if bad:  print('\n'.join('  FAIL  '+m for m in bad))
print(f'\n{len(ok)} passed, {len(warn)} warnings, {len(bad)} failures')
sys.exit(1 if bad else 0)
