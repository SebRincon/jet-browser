import importlib.util
from pathlib import Path


def _script():
    path = Path(__file__).resolve().parents[2] / 'scripts' / 'audit_local_routing.py'
    spec = importlib.util.spec_from_file_location('audit_local_routing', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_supported_denominator_keeps_all_raw_rows():
    module = _script()
    assert len(module.CASES) == 24
    assert module.EXCLUDED_FROM_SUPPORTED == frozenset({'wiki_ambiguous', 'extract', 'find_in_page'})
    rows = [{'case': case_id, 'passed': case_id != 'wiki_ambiguous'} for case_id, _, _ in module.CASES]
    stats = module.agreement(rows)
    assert stats['raw_cases'] == 24
    assert stats['raw_diagnostic_agreement'] == 23
    assert stats['supported_cases'] == 21
    assert stats['supported_case_agreement'] == 21
    assert module.LOCAL_MODELS == ('qwen4b_semif_shared', 'lfm_rlcd', 'laya_mlx', 'laya_typed')
