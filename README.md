# Matrix User Manager 🛠️

> Interactive CLI tool for managing Matrix (Synapse) users inside Docker containers.  
> Built for reliability and real-world DevOps workflows with comprehensive error handling.

[![License: MIT](https://img.shields.io/badge/License-MIT-2ea44f?style=for-the-badge&logo=github&logoColor=white)](#license)
[![Postgres](https://img.shields.io/badge/Postgres-336791?style=for-the-badge&logo=postgres&logoColor=white)](#features)
[![SQLite](https://img.shields.io/badge/SQLite-07405E?style=for-the-badge&logo=sqlite&logoColor=white)](#features)
[![Status](https://img.shields.io/badge/status-production_ready-2ea44f?style=for-the-badge)](#)

---

## Overview

**Matrix User Manager** is a comprehensive Bash-based interactive utility designed for Matrix/Synapse administrators. It eliminates the need to manually run SQL queries or enter containers, providing a safe and user-friendly interface for common user management tasks.

**Key Benefits:**
- 🔍 **Auto-detection**: Automatically finds your Synapse and PostgreSQL containers
- 🛡️ **Safe Operations**: Built-in safeguards for SQLite write operations (container stop/start)
- 🎨 **Dual UI**: Beautiful `whiptail` interface with smart fallback to text UI
- 📊 **Rich Information**: View user details including devices, room memberships, and creation dates
- 🔐 **Secure Password Handling**: Multiple bcrypt hashing methods with fallback options
- 📋 **Comprehensive Logging**: Detailed operation logs for troubleshooting

---

## Features

### Core Functionality
- ✅ **Auto-detect** Synapse & PostgreSQL containers
- ✅ **Dual Database Support**: PostgreSQL and SQLite Synapse installations
- ✅ **Interactive UI**: `whiptail` TUI with intelligent text fallback
- ✅ **Safe SQLite Operations**: Handles container stop/start for write operations
- ✅ **Comprehensive Error Handling**: Detailed error messages and recovery suggestions

### User Management Operations
1. **📋 List Users**: View all users with admin status, deactivation state, and creation dates
2. **🔍 Show User Info**: Detailed user information including:
   - User profile (admin status, creation date, user type)
   - Active devices with last seen timestamps
   - Room memberships (joined/invited rooms)
3. **👤 Create User**: Interactive user creation with:
   - Automatic bcrypt password hashing
   - Admin privilege assignment
   - Multiple fallback hashing methods
4. **🔑 Reset Password**: Secure password reset with multiple hashing options
5. **❌ Deactivate User**: Soft delete (disable account without data loss)
6. **✅ Reactivate User**: Re-enable previously deactivated accounts
7. **💾 Database Backup**: 
   - PostgreSQL: Full `pg_dump` backup
   - SQLite: Safe database file copy with integrity checks
8. **⚡ Custom SQL Queries**: Execute custom queries with formatted output

### Advanced Features
- **🏠 Auto-Configuration**: Reads `homeserver.yaml` to extract domain and database settings
- **🔐 Multiple Hash Methods**: 
  - Synapse native `hash_password` tool
  - bcrypt (container and host)
  - SHA256 fallback
  - Manual hash input support
- **📊 Smart Output**: CSV data formatted as aligned tables
- **🛠️ Container Management**: Automatic package manager detection and bcrypt installation
- **📝 Detailed Logging**: All operations logged with timestamps

---

## Requirements

### System Requirements
- **Docker**: Running Synapse container(s)
- **Bash**: Version 4.0+
- **Basic Unix Tools**: `awk`, `sed`, `grep`, `cat`, `date`

### Optional (Auto-installed)
- **whiptail**: For enhanced UI (auto-installs if desired)
- **sqlite3**: Required for SQLite write operations (auto-installs if needed)
- **python3-bcrypt**: For secure password hashing (auto-installs in container)

### Supported Synapse Deployments
- ✅ Docker Compose setups
- ✅ PostgreSQL backend
- ✅ SQLite backend (with safe write handling)
- ✅ Custom container names
- ✅ Multiple container environments

---

## Installation & Setup

### Quick Start
```bash
# Clone the repository
git clone https://github.com/Ilia-shakeri/matrix_user_manager.git
cd matrix_user_manager

# Make executable
chmod +x matrix_user_manager.sh

# Run with auto-detection
./matrix_user_manager.sh
```

### Manual Container Selection
If auto-detection fails, the script will prompt you to manually select containers:
```bash
# View available containers first
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

# Run script and manually specify containers when prompted
./matrix_user_manager.sh
```

---

## Configuration

### Automatic Configuration
The script automatically:
1. **Detects Containers**: Scans for Synapse and PostgreSQL containers
2. **Finds Config**: Locates `homeserver.yaml` in common paths:
   - `/data/homeserver.yaml`
   - `/data/synapse/homeserver.yaml`
   - `/etc/matrix-synapse/homeserver.yaml`
   - `/app/homeserver.yaml`
   - Custom paths via user input
3. **Extracts Settings**: Parses domain, database type, and connection details
4. **Validates Access**: Tests database connectivity before proceeding

### Database Support

#### PostgreSQL
- **Auto-detected** from `homeserver.yaml` psycopg2 configuration
- **Connection Details**: Extracted automatically (host, port, user, database)
- **Password Handling**: Secure prompt if not found in config
- **Backup**: Full `pg_dump` with compression

#### SQLite
- **Auto-detected** from `homeserver.yaml` sqlite3 configuration
- **Safe Writes**: Automatic container stop/start for write operations
- **File Permissions**: Preserves original ownership and permissions
- **WAL Mode Support**: Handles SQLite Write-Ahead Logging
- **Backup**: Complete database file copy with integrity verification

---

## Usage Examples

### Basic Operations
```bash
# Start the script
./matrix_user_manager.sh

# Example workflow:
# 1. Select "List all users" to see current users
# 2. Select "Create new user" to add a user
# 3. Enter username: alice
# 4. Enter password: (secure input)
# 5. Choose admin privileges: yes/no
# 6. Confirm creation
```

### User Information Detail
When viewing user information, you'll see:
```
=== USER INFORMATION ===
username,admin,deactivated,created,user_type
@alice:matrix.example.com,NO,NO,2024-01-15 10:30:42,NULL

=== USER DEVICES ===
device_id,display_name,last_seen
ABCDEFGHIJ,Alice's Phone,2024-01-15 14:22:10
KLMNOPQRST,Alice's Laptop,2024-01-15 09:15:33

=== ROOM MEMBERSHIPS ===
room_id,membership
!roomid1:matrix.example.com,join
!roomid2:matrix.example.com,join
```

### Password Security Options
The script offers multiple password hashing methods:
1. **Synapse Native** (preferred): Uses Synapse's built-in `hash_password` tool
2. **bcrypt Container**: Uses bcrypt module inside Synapse container
3. **bcrypt Host**: Uses bcrypt module on host system
4. **Manual Hash**: For pre-generated bcrypt hashes
5. **Fallback Hash**: SHA256 with security warning

---

## Advanced Features

### Custom SQL Queries
Execute any SQL query against your Synapse database:
```sql
-- Example queries you can run:

-- Find users by domain
SELECT name FROM users WHERE name LIKE '%@example.com';

-- Recent user activity
SELECT u.name, MAX(d.last_seen) as last_activity 
FROM users u 
JOIN devices d ON u.name = d.user_id 
GROUP BY u.name 
ORDER BY last_activity DESC;

-- Room statistics
SELECT COUNT(*) as total_rooms FROM rooms;
```

### Database Backups
- **PostgreSQL**: Creates compressed SQL dump
- **SQLite**: Creates binary database copy
- **Timestamped**: Automatic timestamp in filename
- **Size Reporting**: Shows backup file size
- **Integrity**: Verifies backup completion

### Error Recovery
The script includes comprehensive error handling:
- **Container Issues**: Helps identify missing or stopped containers
- **Permission Problems**: Guides through permission fixes
- **Database Locks**: Handles SQLite WAL mode and busy databases
- **Missing Dependencies**: Auto-installs required packages
- **Network Issues**: Provides connectivity troubleshooting

---

## Troubleshooting

### Common Issues

#### "No Synapse container found"
```bash
# Check running containers
docker ps

# Look for stopped containers
docker ps -a

# Start your Synapse container
docker start synapse_container_name
```

#### "Cannot connect to PostgreSQL database"
- Verify PostgreSQL container is running
- Check credentials in `homeserver.yaml`
- Ensure PostgreSQL is accepting connections

#### "SQLite database locked"
- Stop Synapse container temporarily
- Check for WAL mode files (`.db-wal`, `.db-shm`)
- Restart Synapse container

#### "bcrypt not available"
The script will offer to install bcrypt automatically:
```bash
# Container installation (recommended)
apt-get install python3-bcrypt

# Or host installation
pip3 install bcrypt
```

### Debug Mode
Enable detailed logging:
```bash
# View the log file
tail -f matrix_user_manager.log

# Check recent operations
grep "$(date '+%Y-%m-%d')" matrix_user_manager.log
```

---

## Security Considerations

### Password Handling
- **Secure Input**: Passwords never displayed on screen
- **bcrypt Hashing**: Industry-standard password hashing
- **No Storage**: Passwords not stored in logs or temp files
- **Multiple Methods**: Fallback options for different environments

### Database Access
- **Read-Only Queries**: Safe for production systems
- **Write Safeguards**: Confirmation prompts for destructive operations
- **Backup Before Changes**: Recommended for SQLite operations
- **Permission Preservation**: Maintains original file ownership

### Container Security
- **Minimal Privileges**: Only necessary container access
- **Temporary Files**: Automatic cleanup of temp files
- **Log Sanitization**: Sensitive data excluded from logs

---

## File Structure

```
matrix_user_manager/
├── matrix_user_manager.sh     # Main script
├── README.md                  # This file
├── LICENSE                    # MIT License
└── assets/                   # Screenshots and media
    ├── whiptail-menu.png
    └── whiptail-menu2.png
```

---

## Contributing

Contributions are welcome! Please:

1. **Fork** the repository
2. **Create** a feature branch
3. **Test** thoroughly with both PostgreSQL and SQLite
4. **Update** documentation if needed
5. **Submit** a pull request

### Development Guidelines
- Follow existing bash style
- Add error handling for new features
- Update help text and comments
- Test on multiple container setups

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Changelog

### Latest Version
- ✅ Enhanced bcrypt installation and detection
- ✅ Improved SQLite write operation safety
- ✅ Better error messages and recovery suggestions
- ✅ Multiple password hashing fallback methods
- ✅ Comprehensive logging and debugging
- ✅ Auto-detection improvements
- ✅ UI/UX enhancements

### Previous Versions
- Basic user management operations
- PostgreSQL and SQLite support
- Whiptail UI implementation
- Container auto-detection

---

## Support

If you encounter issues:

1. **Check the logs**: `matrix_user_manager.log`
2. **Review troubleshooting**: See section above
3. **Open an issue**: Include log excerpts and container setup details
4. **Community help**: Matrix community rooms

---

**Made with ❤️ for the Matrix community**
