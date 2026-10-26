#!/usr/bin/env python3
"""Placeholder codesigning material for an IPA that someone else re-signs.

The release build needs a provisioning profile for every bundle (rules_apple reads the bundle id,
team, entitlements and developer certificate from it), but it never checks that Apple issued the
profile. This script writes self-signed profiles for the configuration's bundle id and team, signed
with build-system/fake-codesigning/certs/SelfSigned.p12, plus that certificate, in the layout
`Make.py build --codesigningInformationPath` reads:

    <destination>/profiles/<name>.mobileprovision
    <destination>/certs/SelfSigned.p12

The resulting IPA installs nowhere: whoever holds the real signing identity re-signs every bundle
with their own profiles (docs/telesrv-signing.md). Bundle ids and the app group are compiled into
the app and must not change when it is re-signed.

macOS only (`security`, `openssl`). Usage:

    python3 build-system/Make/PlaceholderCodesigning.py \\
        --configurationPath build-system/darkmoon-configuration.json \\
        --destination "$RUNNER_TEMP/codesign"
"""

import argparse
import base64
import datetime
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

# Bundle id suffix -> profile file name, as BuildConfiguration.copy_profiles_from_directory maps them.
PROFILES = [
    ('', 'Telegram'),
    ('.Share', 'Share'),
    ('.NotificationContent', 'NotificationContent'),
    ('.NotificationService', 'NotificationService'),
    ('.SiriIntents', 'Intents'),
    ('.Widget', 'Widget'),
    ('.BroadcastUpload', 'BroadcastUpload'),
]

BASE_PATH = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_CERTS_PATH = os.path.join(BASE_PATH, 'build-system', 'fake-codesigning', 'certs')
# Its DeveloperCertificates entry is SelfSigned.p12's certificate; it is the template of every field
# the build does not care about.
TEMPLATE_PROFILE = os.path.join(BASE_PATH, 'build-system', 'fake-codesigning', 'profiles', 'Telegram.mobileprovision')


def run(arguments, input_data=None, check=True):
    result = subprocess.run(arguments, input=input_data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        sys.stderr.write('Command failed: {}\n{}\n'.format(' '.join(arguments), result.stderr.decode('utf-8', 'replace')))
        sys.exit(1)
    return result


def decode_profile(path):
    data = run(['openssl', 'smime', '-inform', 'der', '-verify', '-noverify', '-in', path]).stdout
    return plistlib.loads(data)


def entitlements(team_id, bundle_id, base_bundle_id, is_main_app):
    result = {
        'application-identifier': '{}.{}'.format(team_id, bundle_id),
        'com.apple.developer.team-identifier': team_id,
        'keychain-access-groups': ['{}.*'.format(team_id)],
        'get-task-allow': False,
        'com.apple.security.application-groups': ['group.{}'.format(base_bundle_id)],
    }
    if is_main_app:
        # Make.py reads the push environment from the main app's profile and refuses a profile
        # without one. The re-signing side replaces it with what its own profile allows.
        result['aps-environment'] = 'production'
        result['com.apple.developer.associated-domains'] = '*'
        result['com.apple.developer.usernotifications.communication'] = True
    return result


def make_profile(template, team_id, bundle_id, base_bundle_id, is_main_app):
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0, tzinfo=None)
    profile = {
        'AppIDName': 'Placeholder {}'.format(bundle_id),
        'ApplicationIdentifierPrefix': [team_id],
        'CreationDate': now,
        'Platform': ['iOS'],
        'IsXcodeManaged': False,
        'DeveloperCertificates': template['DeveloperCertificates'][:1],
        'Entitlements': entitlements(team_id, bundle_id, base_bundle_id, is_main_app),
        'ExpirationDate': now + datetime.timedelta(days=3650),
        'Name': 'Placeholder {}'.format(bundle_id),
        'ProvisionsAllDevices': True,
        'TeamIdentifier': [team_id],
        'TeamName': 'Placeholder',
        'TimeToLive': 3650,
        'UUID': str(uuid.uuid4()).upper(),
        'Version': 1,
    }
    return plistlib.dumps(profile, fmt=plistlib.FMT_XML)


def sign_profile(plist_data, destination, keychain, identity):
    with tempfile.NamedTemporaryFile(suffix='.plist', delete=False) as file:
        file.write(plist_data)
        plist_path = file.name
    try:
        run(['security', 'cms', '-S', '-k', keychain, '-N', identity, '-i', plist_path, '-o', destination])
    finally:
        os.unlink(plist_path)


def import_identity(p12_path, keychain, keychain_password, work_dir):
    """Imports SelfSigned.p12 (empty password). macOS refuses some empty-password p12 files, so a
    failed import is retried with a copy re-exported under a password."""
    if run(['security', 'import', p12_path, '-k', keychain, '-P', '', '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'], check=False).returncode == 0:
        return
    pem_path = os.path.join(work_dir, 'identity.pem')
    converted = False
    for legacy in ([], ['-legacy']):
        if run(['openssl', 'pkcs12', '-in', p12_path, '-passin', 'pass:', '-nodes', '-out', pem_path] + legacy, check=False).returncode == 0:
            converted = True
            break
    if not converted:
        sys.stderr.write('Could not read {}\n'.format(p12_path))
        sys.exit(1)
    repacked_path = os.path.join(work_dir, 'identity.p12')
    run(['openssl', 'pkcs12', '-export', '-in', pem_path, '-out', repacked_path, '-passout', 'pass:placeholder',
         '-certpbe', 'PBE-SHA1-3DES', '-keypbe', 'PBE-SHA1-3DES', '-macalg', 'sha1'])
    run(['security', 'import', repacked_path, '-k', keychain, '-P', 'placeholder', '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--configurationPath', required=True, help='The build configuration JSON (bundle_id, team_id).')
    parser.add_argument('--destination', required=True, help='Directory to write profiles/ and certs/ into.')
    parser.add_argument('--certsPath', default=DEFAULT_CERTS_PATH, help='Directory holding SelfSigned.p12.')
    parser.add_argument('--keychain', default=None, help='Keychain to import the signing identity into (default: a temporary one, deleted afterwards).')
    parser.add_argument('--keychainPassword', default=None, help='Password of --keychain.')
    args = parser.parse_args()

    with open(args.configurationPath) as file:
        configuration = json.load(file)
    bundle_id = configuration['bundle_id']
    team_id = configuration['team_id']

    p12_path = os.path.join(args.certsPath, 'SelfSigned.p12')
    template = decode_profile(TEMPLATE_PROFILE)
    certificate_der = template['DeveloperCertificates'][0]
    certificate_pem = '-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n'.format(base64.encodebytes(certificate_der).decode('ascii').strip())
    subject = run(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'oneline,-esc_msb'], input_data=certificate_pem.encode('ascii')).stdout.decode('utf-8')
    if 'CN = ' not in subject:
        sys.stderr.write('Could not read the signing identity of {}\n'.format(TEMPLATE_PROFILE))
        sys.exit(1)
    identity = subject.split('CN = ')[-1].split(',')[0].strip()

    profiles_path = os.path.join(args.destination, 'profiles')
    certs_path = os.path.join(args.destination, 'certs')
    os.makedirs(profiles_path, exist_ok=True)
    os.makedirs(certs_path, exist_ok=True)
    shutil.copyfile(p12_path, os.path.join(certs_path, 'SelfSigned.p12'))

    work_dir = tempfile.mkdtemp()
    temporary_keychain = args.keychain is None
    keychain = args.keychain or os.path.join(work_dir, 'placeholder-profiles.keychain-db')
    keychain_password = args.keychainPassword or str(uuid.uuid4())
    try:
        if temporary_keychain:
            run(['security', 'create-keychain', '-p', keychain_password, keychain])
            run(['security', 'set-keychain-settings', keychain])
        run(['security', 'unlock-keychain', '-p', keychain_password, keychain])
        import_identity(p12_path, keychain, keychain_password, work_dir)
        run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, keychain], check=False)

        for suffix, name in PROFILES:
            profile_bundle_id = bundle_id + suffix
            data = make_profile(template, team_id, profile_bundle_id, bundle_id, is_main_app=(suffix == ''))
            destination = os.path.join(profiles_path, name + '.mobileprovision')
            sign_profile(data, destination, keychain, identity)
            print('{} -> {}'.format(profile_bundle_id, destination))
    finally:
        if temporary_keychain:
            run(['security', 'delete-keychain', keychain], check=False)
        shutil.rmtree(work_dir, ignore_errors=True)

    print('Signing identity: {}'.format(identity))


if __name__ == '__main__':
    main()
