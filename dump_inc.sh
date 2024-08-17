#!/bin/sh

# commands
dump_cmd="dump -C32 -b64 -aunL -f -"
compress_cmd="gzip -q -$compression_level"
ssh_opt="-qS /tmp/rd-$(date '+%m%d%H%M%Y.%S') "

# date parts
sdate=$(date "+%Y%m%d")
month=$(date -v-1m "+%B")
week_day=$(date "+%A")
week_d=$(date "+%u") 
month_d=$(date "+%d")

usage(){
cat <<EOF

Usage:
    dump_inc.sh -c /letc/dump_bkp.conf
        - make level 9 backup according to configuration file
    dump_inc.sh -m /usr -c /letc/dump_bkp.conf
        - make level 9 backup of /usr according to configuration file settings
    dump_bkp -m /usr -p /backup/somedir -s 'user@host.local' -z 1
        - make level 9 bachup of /usr to ssh user@host.local 
          remote dir /backup/somedir, compression level 1
    dump_bkp -h
        - extented help with Configuration file format

Options:
    -c config file
    -m mountpoint to backup
    -p backup path
    -s ssh connection string
    -z compression level (default 9)
    -h help
  
EOF
}

help(){
cat <<EOF

Directory Structure:

backup_path
    hostname
        __hdd_info
            _latest -> 20160825
            20071203
            20090304
            20160825
        _root_
        usr
        var
        var~log
        mnt~storage
        
    Script creates "hostname" directory in backup_path location.
    Included directories are:
        __hdd_info - contains information about disk partitioning of backed up host
            Each directory inside named as date YYYYMMDD when backup was done and contains
            the following set of files:
                devlist - is an output of `camcontrol devlist`, all hw disks
                fstab - the fstab of backed up system
                *.gpart - backup of gpt partition of each drive
            Only changes in paritioning scheme are tracked in these directories. If there were
            no changes in the backup - the directory will not be created.
            _latest - is a symlink to the most recent directory
        _root_ - this is name for the back up of the root "/" filesystem
            All other filesystems shown as their mountpoints replacing "/" to "~" like this
        usr for "/usr"
        var~log for "/var/log"
        mnt~storage1 for "/mnt/storage1"
            Each filesystem backup directory holds: 
                - a set of compressed *.dump.gz files
                - mtree info of this filesystem
                - dumpdates file
                
File Naming convension:
    dump files have extension dump.gz
    mtree files have extension mtree
    
    0.base - this is a dump level 0 backup.
        When any level dump file is created scripts checks if level 0 dump esits.
        If not - then level 0 dump is created instead of expected level
    
    YYYYMMDD.monthly.1.jan - monthly level 1 backup. It is made on the 1st day of each month,
        but named after previous one, to be shure that it covers the whole month it is named for
    
    YYYYMMDD.weekly.2 - weekly level 2 backup. It is made on the 1st day (monday) of each week
    
    YYYYMMDD.daily.?.tuesday - daily bakup, backup level numbering is the following:
        4 - Tuesday 
        3 - Wednesday
        6 - Thursday         
        5 - Friday
        8 - Saturday
        7 - Sunday
        
    YYYYMMDD.manual.9 - manually called backup
    
Manual backup:
    There are two ways to make manual dump:
        1. Filesystem already configured in config file.
            In this case the script should be called with 2 prameters:
            -c config_file -m filesystem 
            The dump of level 9 and mtree files will be created in the default location
        2. Fully manual dump
            Call the script with at least 2 parameters:
            -m filesystem -p backup path
            The dump of level 9 will be created in target directory without mtree file and 
            additional data. Such file will have the following name:
           YYYYMMDD.hostname.mointpoint.manual.9.dump.gz
            where mountpoint is named in the same way as folders above

Files conflict resolution:
    If the aimed dump file name already exists, then ~ followed by index is added to the 
    date part of filename. The same rule is applied to the folders in __hdd_info dir.
    YYYYMMDD~1.filename 
    YYYYMMDD~2.filename

Configuration file format:
    backup_list=root var logs usr
        - list of backup targets
          for each backup target the following options available:
    root_mount_point=/
        - mounted filesystem MANDATORY
    root_backup_path=/backup
        - backup structure location MANDATORY
    root_ssh_string=user@host.local
        - ssh connection string for remote backup location
          backup path on the remote host in this case
    root_compression=9 (default)
        - compression level 1-9, 1 - fastest, 9 - best compression
    root_older=13w (default)
        - delete backups oder than: s(econd) m(inute) h(our) d(ay) w(eek)
          base and monthly backups are not deleted

EXAMPLE:
    backup_list=root usr
    root_mount_point=/
    root_backup_path=/backup
    usr_mount_point=/usr
    usr_backup_path=bakup/d2
    usr_ssh_string=user@host.local
    usr_compression=5
    usr_older=30d
EOF
}



# check_mount_point mount_point
#   check if mount point exists and mounted
#
check_mount_point(){
    for _mp in $(mount -p -t ufs | awk '{print $2}'); do
        [ "$1" = "$_mp" ] && return 0
    done
    return 1
}

# check_ssh 
#   check if ssh connection may be established
#   setup multiplex ssh connection
#
check_ssh(){
    [ ! -z "$ssh_string" ] && \
        if ssh -M -o "ControlPersist 30s" $ssh_opt $ssh_string exit 0; then 
            ssh_cmd="ssh $ssh_opt $ssh_string" 
            return 0
        else
            echo "Backup failed: Unable to establish ssh session $ssh_string" 
            return 1
        fi
    ssh_cmd=""
    return 0
}

# check_bkp path
#   check id backup path exists
#
check_bkp_path(){
    if $ssh_cmd [ ! -d "$bkp_path" ]; then
    	echo "Backup failed: Unable to access backup directory!"
    	return 1
    fi
    return 0
}

# read_config mount_point
#   parse config file for mount_point config
#   or for rutine backup
#
readConfig(){
    local man_fs=$1
    . $conf_file
    [ -z "$backup_list" ] && { echo "Configuration file $conf_file read error!"; exit 1; }
    for mp in $backup_list; do
        res=$(($res+1))
        eval mount_point="\$${mp}_mount_point"
        eval bkp_path="\$${mp}_backup_path"
        eval ssh_string="\$${mp}_ssh_string"
        eval compression_level="\$${mp}_compression"
        compression_level=${compression_level:-9}
        eval older="\$${mp}_older"
        older=${older:-13w}

        check_mount_point $mount_point || { echo "Invalid mounting point $mount_point! Skip $mp configuration"; continue; }
        [ -z "$bkp_path" ] && { echo "Backup path is missing! Skip $mp configuration"; continue; }
        if ! ([ $compression_level -ge 1 ] && [ $compression_level -le 9 ]); then
           echo "Ivalid compression level: using compression_level=9"
           compression_level=9
        fi
        if (echo $older | egrep -q "^[0-9]+[smhdw]{1}$"); then
            older="+$older"
        else
            echo "Invalid older set: using 13w"
            older="+13w"
        fi

        ([ ! -z "$man_fs" ] && [ "$mount_point" != "$man_fs" ]) && continue
        check_ssh || continue
        check_bkp_path || continue
        bkp_dir=$bkp_path/$(hostname)/$(echo $mount_point | sed 's/^\/$/_root_/' | sed 's/^\///' | sed 's/\//~/g')
        res=$(($res-1))
        backup
        res=$(($res+$?))
    done
    return $res
}

# post_backup
#   Post backup rutine for configured backups
#   delete old backups
#   save dumpdates, fstab files, gpart partition dumps
#
post_backup(){
    echo "Post backup routine..."
# dumpdates file
    cat /etc/dumpdates | $ssh_cmd dd of="$bkp_dir/dumpdates"
# delete old dumps
    [ $dump_level -gt 1 ] && $ssh_cmd find $bkp_dir -name "*.[$dump_level-9].*" -mtime $older -delete

    hdd_info_dir=$(dirname $bkp_dir)/__hdd_info/$sdate
    index=0
    while $ssh_cmd [ -d "$hdd_info_dir" ]; do
        index=$(($index+1));
        hdd_info_dir=$(dirname $bkp_dir)/__hdd_info/$sdate~$index
    done
    $ssh_cmd mkdir -p $hdd_info_dir
# fstab file
    cat /etc/fstab | $ssh_cmd dd of="$hdd_info_dir/fstab"
# gpart backup
    for dev in $(gpart show | grep '=>' | awk '{print $4}'); do 
        gpart backup $dev | $ssh_cmd dd of="$hdd_info_dir/$dev.gpart.backup" 
    done
# devices list
    camcontrol devlist | $ssh_cmd dd of="$hdd_info_dir/devlist"

# trace hdd_info changes
# _latest is a link to last date dir
    if [ -z "$ssh_cmd" ]; then
        diff -s $hdd_info_dir $(dirname $hdd_info_dir)/_latest > /dev/null 2>&1 && rm -rf $hdd_info_dir || \
        ( cd $(dirname $hdd_info_dir) && ln -sF $(basename $hdd_info_dir) _latest )
    else
        $ssh_cmd "diff -s $hdd_info_dir $(dirname $hdd_info_dir)/_latest > /dev/null 2>&1 && \
        rm -rf $hdd_info_dir || \
        ( cd $(dirname $hdd_info_dir) && ln -sF $(basename $hdd_info_dir) _latest )"
    fi

#close ssh connection
[ ! -z "$ssh_string" ] && ssh -O exit $ssh_opt $ssh_string 
    return 0
}

# backup "manual"
#   calculate level, create backup and mtree
#   "manual" argument means to create standalone level 9 dump
#
backup(){
    $ssh_cmd mkdir -p $bkp_dir || { echo Backup failed: Unable to create $bkp_dir; return 1; }

# create .snap directory in the root of each  dumped filesystem
    mkdir -p $mount_point/.snap
    chown root:operator $mount_point/.snap
    chmod 0770 $mount_point/.snap
    
    if [ ! -z "$1" ] && [ $1 = "manual" ]; then
        f_mid="$(hostname).$(echo $mount_point | sed 's/^\/$/_root_/' | sed 's/^\///' | sed 's/\//~/g').manual.$dump_level"
    elif [ ! -z $dump_level ] && [ $dump_level -eq 9 ]; then
        f_mid="manual.$dump_level"
    elif [ $month_d -eq 1 ]; then
        dump_level=1
        f_mid="monthly.$dump_level.$month"
    elif [ $week_d -eq 1 ]; then
        dump_level=2
        f_mid="weekly.$dump_level"
    else
        case $week_d in
            2) dump_level=4 ;;
            3) dump_level=3 ;;
            4) dump_level=6 ;;
            5) dump_level=5 ;; 
            6) dump_level=8 ;; 
            7) dump_level=7 ;; 
        esac
        f_mid="daily.$dump_level.$week_day"
    fi

    echo "Creating $f_mid backup of $mount_point"
    filename=$sdate.$f_mid

    if [ $dump_level -ne 9 ] && $ssh_cmd [ ! -f "$bkp_dir/0.base.dump.gz" ]; then
        echo Base level 0 dump missing. Creating new base dump.
        filename="0.base"
        dump_cmd="$dump_cmd -h0"
        dump_level=0
    else
        index=0
        while $ssh_cmd [ -f "$bkp_dir/$filename.dump.gz" ]; do
            index=$(($index+1));
            filename=$sdate~$index.$f_mid
        done
    fi

    #touch $bkp_dir/$filename.dump.gz
    $dump_cmd -"$dump_level" $mount_point | $compress_cmd | $ssh_cmd dd of="$bkp_dir/$filename.dump.gz"


    if [ $? -eq 0 ]; then
        # mtree file
        [ -z $1 ] && mtree -cxp $mount_point -K sha256 | $compress_cmd | $ssh_cmd dd of="$bkp_dir/$filename.mtree.gz"
        echo "Success: $filename dump of $mount_point complete";
        [ $dump_level -ne 9 ] && post_backup $bkp_dir $filename;
        return 0;
    else
        echo "Failure: $filename dump of $mount_point failed";
        return 1;
    fi;
}

# script body
#   read options, run necessary backup rutine
#
while getopts "c:m:p:s:z:h" OPT; do
    case $OPT in
        c) 
            if [ -f "$OPTARG" ]; then
                conf_file=$OPTARG
            else
                echo "Configuration file $OPTARG not found"
                exit 1
            fi
        ;;
        m)
            if check_mount_point $OPTARG;  then
                mount_point=$OPTARG
            else
                echo "Invalid mointing point $OPTARG"
                exit 1
            fi
        ;;
        p) bkp_path=$OPTARG ;;
        s) ssh_string=$OPTARG ;;
        z) 
            if [ $OPTARG -ge 1 ] && [ $OPTARG -le 9 ]; then
                compression_level=$OPTARG
            else
                echo "Ivalid compression level: should be from 1 to 9"
                exit 1
            fi
        ;;
        h) usage; help; exit 0 ;;
        \?) usage; exit 1 ;;
    esac
done
[ $OPTIND -ne 1 ] || usage

if [ ! -z "$mount_point" ] && [ ! -z "$bkp_path" ]; then
    echo Manual level 9 backup of $mount_point to $ssh_string:$bkp_path with compression level $compression_level
    dump_level=9
    check_ssh || exit 1
    check_bkp_path || exit 1
    bkp_dir=$bkp_path
    backup "manual"
    res=$?
elif [ ! -z "$conf_file" ] && [ ! -z $mount_point ]; then
    echo Manual level 9 backup of $mount_point according to $conf_file configuration
    dump_level=9
    readConfig $mount_point
elif [ ! -z "$conf_file" ]; then
    echo Backup routine according to $conf_file configuration
    readConfig
else
    usage
fi

exit $res;


