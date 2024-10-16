#!/bin/bash

get_mariadb_parameters() {
  echo "Fetching MariaDB parameters..."
  mysql -u root -p -e "SHOW VARIABLES" > mariadb_variables.txt
}

# Function to get current VM parameters
get_vm_parameters() {
  echo "Fetching VM parameters..."
  echo "CPU Info:"
  lscpu > vm_info.txt
  echo "Memory Info:"
  free -h >> vm_info.txt
  echo "Disk Info:"
  df -h >> vm_info.txt
  echo "IO Scheduler:"
  cat /sys/block/sda/queue/scheduler >> vm_info.txt
}

analyze_parameters() {
  echo "Analyzing parameters and suggesting configuration changes..."

  echo "Based on the current parameters, consider the following changes:"

  echo "1. Increase innodb_buffer_pool_size"
  echo "   Current value: $(grep 'innodb_buffer_pool_size' mariadb_variables.txt | awk '{print $2}')"
  echo "   Suggestion: Set it to 70-80% of your total memory for better InnoDB performance."

  echo "2. Optimize innodb_log_file_size"
  echo "   Current value: $(grep 'innodb_log_file_size' mariadb_variables.txt | awk '{print $2}')"
  echo "   Suggestion: Set it to 25% of your innodb_buffer_pool_size for improved write performance."

  echo "3. Set innodb_flush_method to O_DIRECT"
  echo "   Current value: $(grep 'innodb_flush_method' mariadb_variables.txt | awk '{print $2}')"
  echo "   Suggestion: Use O_DIRECT to avoid double buffering and improve I/O performance."

  echo "4. Enable query cache if not already enabled"
  echo "   Current value: $(grep 'query_cache_size' mariadb_variables.txt | awk '{print $2}')"
  echo "   Suggestion: Enable query cache to improve performance of repeated queries."

  echo "5. Adjust max_connections"
  echo "   Current value: $(grep 'max_connections' mariadb_variables.txt | awk '{print $2}')"
  echo "   Suggestion: Increase this value if you expect high concurrency."

  echo "6. Check VM swappiness"
  echo "   Current swappiness: $(cat /proc/sys/vm/swappiness)"
  echo "   Suggestion: Set vm.swappiness to 10 or 1 to reduce swapping and improve performance."

  echo "7. Optimize disk I/O scheduler"
  echo "   Current scheduler: $(cat /sys/block/sda/queue/scheduler)"
  echo "   Suggestion: Use 'noop' or 'deadline' scheduler for SSDs."

}

# Main script execution
get_mariadb_parameters
get_vm_parameters
analyze_parameters

echo "Optimization suggestions are complete."
