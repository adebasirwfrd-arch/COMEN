#!/usr/bin/env python3
"""Extract code blocks from BLUEPRINT3.MD into project files (one-time scaffold helper)."""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BP = os.path.join(ROOT, 'BLUEPRINT', 'BLUEPRINT3.MD')

lines = open(BP, encoding='utf-8').read().split('\n')


def block(start: int) -> str:
    """Return block content whose opening fence is at 1-based line `start`."""
    assert lines[start - 1].startswith('```'), (start, lines[start - 1])
    out = []
    i = start
    while not lines[i].startswith('```'):
        out.append(lines[i])
        i += 1
    return '\n'.join(out) + '\n'


MAP = {
    'supabase/migrations/20260101000001_extensions_enums.sql': [1357],
    'supabase/migrations/20260101000002_identity_tables.sql': [1379],
    'supabase/migrations/20260101000003_core_tables.sql': [1594],
    'supabase/migrations/20260101000004_task_tables.sql': [1767],
    'supabase/migrations/20260101000005_domain_tables.sql': [1902],
    'supabase/migrations/20260101000006_chat_tables.sql': [2151],
    'supabase/migrations/20260101000007_audit_log.sql': [2277],
    'supabase/migrations/20260101000008_fn_core.sql': [2363],
    'supabase/migrations/20260101000009_fn_identity_admin.sql': [2862],
    'supabase/migrations/20260101000010_fn_vendor_contract.sql': [3982],
    'supabase/migrations/20260101000011_fn_task.sql': [4743],
    'supabase/migrations/20260101000012_fn_records.sql': [5596],
    'supabase/migrations/20260101000013_fn_chat.sql': [5829],
    'supabase/migrations/20260101000014_triggers.sql': [6562],
    'supabase/migrations/20260101000015_jobs_cron.sql': [6926, 7625, 7648],
    'supabase/migrations/20260101000016_rls_grants.sql': [7685, 8031],
    'supabase/migrations/20260101000017_seed_reference.sql': [8061, 8192],
    'supabase/seed.sql': [8339],
    'scripts/dev_users.sh': [8400],
    'supabase/functions/deno.json': [8460],
    'supabase/functions/_shared/env.ts': [8471],
    'supabase/functions/_shared/crypto.ts': [8481],
    'supabase/functions/_shared/http.ts': [8505],
    'supabase/functions/_shared/supabase.ts': [8577],
    'supabase/functions/_shared/brevo.ts': [8607],
    'supabase/functions/notify-dispatch/index.ts': [8625],
    'supabase/functions/submit-registration/index.ts': [8707],
    'supabase/functions/admin-actions/index.ts': [8751],
    'supabase/functions/inbound-email/index.ts': [8819],
    'supabase/functions/brevo-webhook/index.ts': [8862],
    'supabase/functions/audit-anchor/index.ts': [8885],
    'lib/core/env.dart': [8999],
    'web/secure_store.js': [9034],
    'lib/core/security/secure_store.dart': [9122],
    'lib/core/security/encrypted_storage.dart': [9156],
    'lib/core/security/device_identity.dart': [9217],
    'lib/core/security/browser_info.dart': [9250],
    'lib/main.dart': [9273],
    'lib/core/errors/app_failure.dart': [9332],
    'lib/core/session/session_controller.dart': [9405],
    'lib/core/session/session_state.dart': [9563],
    'lib/core/router/gate.dart': [9599],
    'lib/features/auth/auth_gateway.dart': [9689],
    'lib/core/security/url_policy.dart': [9759],
    'lib/core/security/fingerprint.dart': [9783],
    'web/index.html': [9829],
    'web/flutter_bootstrap.js': [9851],
    'web/push_sw.js': [9866],
    'lib/data/columns.dart': [9909],
    'lib/core/router/route_rules.dart': [10265],
    'vercel.json': [570],
    '.github/workflows/ci.yml': [10551],
}

only = set(sys.argv[1:])
for path, starts in MAP.items():
    if only and path not in only:
        continue
    full = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    content = '\n'.join(block(s) for s in starts)
    with open(full, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f'{path}: {content.count(chr(10))} lines')
