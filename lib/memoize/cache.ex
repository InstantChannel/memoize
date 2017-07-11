defmodule Memoize.Cache do
  @moduledoc false

  @memory_strategy Application.get_env(:memoize, :memory_strategy, Memoize.MemoryStrategy.Default)

  defp tab(key) do
    @memory_strategy.tab(key)
  end

  defp compare_and_swap(key, :nothing, value) do
    :ets.insert_new(tab(key), value)
  end

  defp compare_and_swap(key, expected, :nothing) do
    num_deleted = :ets.select_delete(tab(key), [{expected, [], [true]}])
    num_deleted == 1
  end

  defp compare_and_swap(key, expected, value) do
    num_replaced = :ets.select_replace(tab(key), [{expected, [], [{:const, value}]}])
    num_replaced == 1
  end

  defp set_result_and_get_waiter_pids(key, result, context) do
    runner_pid = self()
    [{^key, {:running, ^runner_pid, waiter_pids}} = expected] = :ets.lookup(tab(key), key)
    if compare_and_swap(key, expected, {key, {:completed, result, context}}) do
      waiter_pids
    else
      # retry
      set_result_and_get_waiter_pids(key, result, context)
    end
  end

  defp delete_and_get_waiter_pids(key) do
    runner_pid = self()
    [{^key, {:running, ^runner_pid, waiter_pids}} = expected] = :ets.lookup(tab(key), key)
    if compare_and_swap(key, expected, :nothing) do
      waiter_pids
    else
      # retry
      delete_and_get_waiter_pids(key)
    end
  end

  def get_or_run(key, fun, opts \\ []) do
    case :ets.lookup(tab(key), key) do
      # not started
      [] ->
        # calc
        runner_pid = self()
        if compare_and_swap(key, :nothing, {key, {:running, runner_pid, %{}}}) do
          try do
            fun.()
          else
            result ->
              context = @memory_strategy.cache(key, result, opts)
              waiter_pids = set_result_and_get_waiter_pids(key, result, context)
              Enum.map(waiter_pids, fn {pid, _} ->
                                      send(pid, {self(), :completed})
                                    end)
              get_or_run(key, fun)
          rescue
            error ->
              # the status should be :running
              waiter_pids = delete_and_get_waiter_pids(key)
              Enum.map(waiter_pids, fn {pid, _} ->
                                      send(pid, {self(), :failed})
                                    end)
              reraise error, System.stacktrace()
          end
        else
          get_or_run(key, fun)
        end

      # running
      [{^key, {:running, runner_pid, waiter_pids}} = expected] ->
        waiter_pids = Map.put(waiter_pids, self(), :ignore)
        if compare_and_swap(key, expected, {key, {:running, runner_pid, waiter_pids}}) do
          ref = Process.monitor(runner_pid)
          receive do
            {^runner_pid, :completed} -> :ok
            {^runner_pid, :failed} -> :ok
            {:"DOWN", ^ref, :process, ^runner_pid, _reason} -> :ok
          after
            5000 -> :ok
          end

          Process.demonitor(ref, [:flush])
          # flush existing messages
          receive do
            {^runner_pid, _} -> :ok
          after
            0 -> :ok
          end

          get_or_run(key, fun)
        else
          get_or_run(key, fun)
        end

      # completed
      [{^key, {:completed, value, context}}] ->
        case @memory_strategy.read(key, value, context) do
          :retry -> get_or_run(key, fun)
          :ok -> value
        end
    end
  end

  def invalidate() do
    @memory_strategy.invalidate()
  end

  def invalidate(key) do
    @memory_strategy.invalidate(key)
  end

  def garbage_collect() do
    @memory_strategy.garbage_collect()
  end
end
