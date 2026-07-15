print("MONITOR_START")

for sample = 1, 5 do
    print(
        "sample", sample,
        "tick", rtos.tick(),
        "heap", rtos.heap_free(),
        "heartbeat", rtos.heartbeat(),
        "irq", rtos.irq_count()
    )
    rtos.sleep(1000)
end

print("MONITOR_DONE")
