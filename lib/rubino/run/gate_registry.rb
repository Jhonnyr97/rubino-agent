# frozen_string_literal: true

module Rubino
  module Run
    # Process-wide registry of ApprovalGate instances, keyed by run_id.
    # Module-level state (no instance): one hash + one mutex held at the
    # module singleton class.
    #
    # Lifecycle: Executor#start calls +register+ when a run begins and
    # +unregister+ in its +ensure+ block; HTTP decision endpoints call
    # +fetch+ to resolve the gate before forwarding a decision.
    #
    # Single-process only: the gate lives in the Ruby heap, so this does
    # not survive multi-process scaling (Puma workers, forked servers).
    # Decisions routed to the wrong worker silently fail #fetch.
    module GateRegistry
      @gates = {}
      @mutex = Mutex.new

      class << self
        def register(run_id, gate)
          @mutex.synchronize { @gates[run_id] = gate }
        end

        def fetch(run_id)
          @mutex.synchronize { @gates[run_id] }
        end

        def unregister(run_id)
          @mutex.synchronize { @gates.delete(run_id) }
        end

        def reset!
          @mutex.synchronize { @gates.clear }
        end
      end
    end
  end
end
