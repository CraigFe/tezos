from datetime import datetime, timedelta
import pytest
from tools import utils
from client import client_output
from launchers.sandbox import Sandbox

BAKE_ARGS = ['--max-priority', '512', '--minimal-timestamp']
PARAMS = ['--connections', '500', '--bootstrap-threshold', '0']
# 2*cycle_size - (protocol_activation)
CEMENTED_LIMIT = 2*8 - 1
# The whole store is cemented
BATCH_1 = 48
# 2 cycles are pruned in full 5 mode
BATCH_2 = 96

SNAPSHOT_1 = f'snapshot_block_{BATCH_1}.full'
SNAPSHOT_2 = f'snapshot_block_{BATCH_2}.full'

EXPECTED_BLOCK_ERROR = 'Unable to find block'
EXPECTED_COMMAND_ERROR = 'Command failed : Unable to find block'


def clear_cache(sandbox, node_id):
    # Restart node to clear the store's cache
    sandbox.node(node_id).terminate_or_kill()
    sandbox.node(node_id).run()
    assert sandbox.client(node_id).check_node_listening()


@pytest.mark.multinode
@pytest.mark.incremental
@pytest.mark.snapshot
@pytest.mark.slow
class TestMultiNodeStorageReconstruction:

    def test_init(self, sandbox: Sandbox):
        sandbox.add_node(0, params=PARAMS + ['--history-mode', 'archive'])
        # Keep node 3 in the dance
        # History mode by default (full)
        sandbox.add_node(3, params=PARAMS)
        # Allow fast `bake for` by activating the protocol in the past
        last_hour_date_time = datetime.utcnow() - timedelta(hours=1)
        timestamp = last_hour_date_time.strftime("%Y-%m-%dT%H:%M:%SZ")
        utils.activate_alpha(sandbox.client(0), timestamp=timestamp)

    # Node 0 bakes a few blocks
    def test_bake_node0_level_a(self, sandbox: Sandbox, session: dict):
        for _ in range(BATCH_1):
            sandbox.client(0).bake('bootstrap1', BAKE_ARGS)
        session['head_hash'] = sandbox.client(0).get_head()['hash']
        session['head_level'] = sandbox.client(0).get_head()['header']['level']

    # Node 3 tries to reconstruct its storage after the first btach.
    # Reconstruct is expected to fail: nothing to reconstruct
    def test_reconstruct_on_bootstrapped_node(self, sandbox: Sandbox):
        # Stop, reconstruct the storage and restart the node
        sandbox.node(3).terminate_or_kill()
        pattern = 'nothing to reconstruct.'
        with utils.assert_run_failure(pattern):
            sandbox.node(3).reconstruct()
        sandbox.node(3).run()
        assert sandbox.client(3).check_node_listening()

    # Node 0 exports a snapshot
    def test_export_snapshot_batch1(self, sandbox: Sandbox, session: dict):
        node_export = sandbox.node(0)
        session['snapshot_1_head_hash'] = session['head_hash']
        session['snapshot_1_head_level'] = session['head_level']
        file = f'{sandbox.node(0).node_dir}/{SNAPSHOT_1}'
        export_level = session['head_level']
        assert export_level == (BATCH_1 + 1)
        node_export.snapshot_export(
            file, params=['--block', f'{export_level}'])

    # Node 1 import and reconstruct (using the `--reconstruct`
    # flag of the `snapshot import` command)
    def test_node1_import_and_reconstruct(self, sandbox: Sandbox,
                                          session: dict):
        n0_tmpdir = sandbox.node(0).node_dir
        file = f'{n0_tmpdir}/{SNAPSHOT_1}'
        sandbox.add_node(1, snapshot=file, reconstruct=True,
                         params=PARAMS + ['--history-mode', 'archive'])
        assert utils.check_level(sandbox.client(1), session['head_level'])
        clear_cache(sandbox, 1)

    # Test that all the reconstructed blocks can be requested
    # with their metadata
    def test_node1_request_all_blocks_with_metadata(self, sandbox: Sandbox,
                                                    session: dict):
        for i in range(session['head_level']):
            assert utils.get_block_at_level(sandbox.client(1), i)

    # Node 2 import and then reconstruct using the dedicated command.
    def test_import_before_reconstruct(self, sandbox: Sandbox,
                                       session: dict):
        n0_tmpdir = sandbox.node(0).node_dir
        file = f'{n0_tmpdir}/{SNAPSHOT_1}'
        sandbox.add_node(2, snapshot=file)
        assert utils.check_level(sandbox.client(2), session['head_level'])

    # Checking node's 2 storage
    def test_unavailable_blocks_node2(self, sandbox: Sandbox, session: dict):
        # We must fail while requesting those pruned blocks
        for i in range(1, session['snapshot_1_head_level'] - 1):
            with pytest.raises(client_output.InvalidClientOutput) as exc:
                utils.get_block_metadata_at_level(sandbox.client(2), i)
            assert exc.value.client_output.startswith(EXPECTED_COMMAND_ERROR)

    # Call the reconstruct command on Node 2
    def test_reconstruct_after_snapshot_import(self, sandbox: Sandbox):
        # Stop, reconstruct the storage and restart the node
        sandbox.node(2).terminate_or_kill()
        sandbox.node(2).reconstruct()
        sandbox.node(2).run()
        assert sandbox.client(2).check_node_listening()

    # Test that all the reconstructed blocks can be requested
    # with their metadata
    def test_available_blocks_node_2(self, sandbox: Sandbox, session: dict):
        # We should now success requesting those reconstructed blocks
        for i in range(session['head_level']):
            assert utils.get_block_at_level(sandbox.client(2), i)

    # Second batch

    # Bake a few blocks
    def test_bake_node0_level_b(self, sandbox: Sandbox, session: dict):
        for _ in range(BATCH_2 - BATCH_1):
            sandbox.client(0).bake('bootstrap1', BAKE_ARGS)
        session['head_hash'] = sandbox.client(0).get_head()['hash']
        session['head_level'] = sandbox.client(0).get_head()['header']['level']
        assert utils.check_level(sandbox.client(0), session['head_level'])
        assert utils.check_level(sandbox.client(1), session['head_level'])
        assert utils.check_level(sandbox.client(2), session['head_level'])

    # Node 0 exports a snapshot (with no floating to reconstruct)
    def test_export_snapshot_batch2(self, sandbox: Sandbox, session: dict):
        node_export = sandbox.node(0)
        # to export on a cemented cycle
        export_block_level = 64
        export_block = utils.get_block_at_level(sandbox.client(0),
                                                export_block_level)
        export_block_hash = export_block['hash']
        session['snapshot_2_head_hash'] = export_block_hash
        session['snapshot_2_head_level'] = export_block_level
        file = f'{sandbox.node(0).node_dir}/{SNAPSHOT_2}'
        node_export.snapshot_export(
            file, params=['--block', f'{export_block_level}'])

    # Check that node 3 (full bootstrapped) can be reconstructed
    def test_sync_node3(self, sandbox: Sandbox, session: dict):
        assert utils.check_level(sandbox.client(3), session['head_level'])
        clear_cache(sandbox, 3)

    # Checking node's 3 storage
    def test_unavailable_blocks_node3(self, sandbox: Sandbox):
        savepoint = int(sandbox.client(3).get_savepoint())
        assert utils.get_block_at_level(sandbox.client(3), savepoint)
        # We must fail while requesting blocks before savepoint
        for i in range(1, savepoint):
            with pytest.raises(client_output.InvalidClientOutput) as exc:
                utils.get_block_metadata_at_level(sandbox.client(3), i)
            assert exc.value.client_output.startswith(EXPECTED_COMMAND_ERROR)

    def test_reconstruct_command_after_bootstrap(self, sandbox: Sandbox):
        # Stop, reconstruct the storage and restart the node
        sandbox.node(3).terminate_or_kill()
        sandbox.node(3).reconstruct()
        # History mode is now archive
        sandbox.node(3).run()
        assert sandbox.client(3).check_node_listening()

    def test_available_blocks_node3(self, sandbox: Sandbox, session: dict):
        assert sandbox.client(3).get_savepoint() == 0
        assert sandbox.client(3).get_caboose() == 0
        # We should now success requesting those reconstructed blocks
        for i in range(session['head_level']):
            assert utils.get_block_at_level(sandbox.client(3), i)
