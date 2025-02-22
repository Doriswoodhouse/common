create or replace package workshop authid current_user
as

    /* Specify constants for the utility */
    install_path varchar2(100) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/adwc4pm/b/workshop_utilities/o/setup/scripts/';

    procedure install_prerequisites;

    /* Creates a user with privileges required to run demos */
    procedure add_adb_user(user_name varchar2, pwd varchar2);

    /*
    procedure add_dataset
        table_names:  comma separated list of tables.
                      use ALL to add all tables
        debug_on:     will keep logging tables after a data load

    */
    procedure add_dataset(table_names varchar2, debug_on boolean default false);

    /* write message to the log
       use style to format output
       -1 = error       #! Error !# message
        1 = header(h1)  { message }
        2 = header (h2) -> message
        3 = header (h3) ---> message
        4 = list item       -
        null = plain     message
    */
    procedure write (message in varchar2 default null, style number default null);

    /* Execute a procedure or ddl */
    procedure exec (sql_ddl in varchar2, raise_exception in boolean := false);

end workshop;
/

create or replace package body workshop as

    /* write message to the log
       use style to format output
       -1 = error       #! Error !# message
        1 = header(h1)  { message }
        2 = header (h2) -> message
        3 = header (h3) --> message
        4 = list item       -
        null = plan     message
    */
    procedure write
    (
      message in varchar2 default null,
      style   in number default null
    
    ) as
        l_message varchar2(32000);
    
    begin
    
        if message is null then
            return;
        end if;
    
        dbms_output.put_line(to_char(systimestamp, 'DD-MON-YY HH:MI:SS') || ' - ' || message);
    
        -- Add style to the message
        l_message := case style
                        when null then
                            message
                        when -1 then
                            '#! Error !#' || message
                        when 1 then
                            '[- ' || message || ' -]'
                        when 4 then
                            '    - ' || message
                        else
                           substr('------------------------->', (style * -2)) || ' ' || message
                      end;
    
        execute immediate 'insert into workshop_log(execution_time, session_id, username, message) values(:t1, :sid, :u, :msg)'
                using systimestamp, sys_context('USERENV', 'SID'), sys_context('USERENV', 'SESSION_USER'),  l_message;
        commit;
    
    
    end write;
    
    /* Execute a command and log it */
    procedure exec
    (
      sql_ddl in varchar2,
      raise_exception in boolean := false
    
    ) as
    begin
        -- Wrapper for execute immediate
        write(sql_ddl);
        execute immediate sql_ddl;
    
        exception
          when others then
            if raise_exception then
                raise;
            else
                write(sqlerrm, -1);
            end if;
    
    end exec;
    
    /**
    table_names is a comma separated list of tables
    specify ALL to add all data sets.
    **/
    procedure add_dataset(table_names varchar2, debug_on boolean) as
    type t_datasets is table of workshop_datasets%rowtype;
    l_datasets t_datasets;
    l_table_names varchar2(4000);
    c_table_names sys.odcivarchar2list := sys.odcivarchar2list();
    l_count number;
    l_opid  number;
    l_load_op_rec user_load_operations%rowtype;
    start_time date := sysdate;
    
    begin
    
    /**
        1. get the list of tables
        2. drop those that existed
        3. create the tables
        4. load the tables
        5. add constraints
        6. run any post-processor
    **/
    write('begin adding data sets', 1);
    write('debug=' || case when debug_on then 'true' else 'false' end, 2);
    
    -- upper case, no spaces, no newline
    l_table_names := replace(table_names, '\n', '');
    l_table_names := replace(trim(upper(table_names)), ' ', '');
    
    
    -- Check for ALL tables
    if l_table_names  = 'ALL' then
        select *
        bulk collect into l_datasets
        from workshop_datasets
        order by seq;
    else
        -- convert comma separated list of tables
        -- Also, add any dependent tables
    
        with rws as (
          select l_table_names str from dual
        ),
        input_tables as (
            -- comma separated table list
            select *
            from   workshop_datasets
            where  table_name in (
              select regexp_substr (
                       str,
                       '[^,]+',
                       1,
                       level
                     ) value
              from   rws
              connect by level <=
                length ( str ) -
                length ( replace ( str, ',' ) ) + 1
                )
        ),
        dependent_tables as (
            -- additional tables that the input tables require
            select
                jt.dependencies
            from workshop_datasets d,
                 json_table(upper(dependencies), '$[*]' columns (dependencies path '$')) jt,
                 input_tables i
            where d.table_name = i.table_name
        )
        -- combine the input and dependencies
        select *
        bulk collect into l_datasets
        from workshop_datasets
        where table_name in (select dependencies from dependent_tables)
           or table_name in (select table_name from input_tables)
        order by seq
        ;
    
    end if;
    
    write('Input tables', 1);
    write('These tables were requested', 2);
    write(l_table_names, 4);
    write('These tables will be added. The list includes dependent tables that were added automatically', 2);
    
    for i in 1 .. l_datasets.count
    loop
        write(l_datasets(i).table_name, 4);
    end loop;
    
    /**
        Drop tables that will be recreated
    **/
    write('Will recreate tables that already exist', 1);
    
    for i in 1 .. l_datasets.count
    loop
        select count(*)
        into l_count
        from user_tables
        where table_name = l_datasets(i).table_name;
    
        if l_count > 0 then
            exec( 'drop table ' || l_datasets(i).table_name || ' cascade constraints');
        end if;
    end loop;
    write('Done dropping tables', 1);
    
    /**
        Create the tables
    **/
    write('Creating tables', 1);
    
    for i in 1 .. l_datasets.count
    loop
        -- only create tables sourced from object store
        -- otherwise, create the table during the load
        if l_datasets(i).source_uri is null then
            write('deferring create table ' || l_datasets(i).table_name || ' until the load step', 2);
        else
            write('create table ' || l_datasets(i).table_name, 2);
            exec (l_datasets(i)."SQL");
        end if;
    
    end loop;
    write('Done creating tables', 1);
    
    /**
        Load the tables
    **/
    write('Loading tables', 1);
    
    for i in 1 .. l_datasets.count
    loop
        -- load tables that have an object store source
        write ('Loading ' || l_datasets(i).table_name, 2);
    
        if l_datasets(i).source_uri is null then
            -- this is for sources that are derived from other sources (e.g. CTAS)
            exec (l_datasets(i)."SQL");
        else
            begin
                dbms_cloud.copy_data (
                    table_name        => l_datasets(i).table_name,
                    file_uri_list     => l_datasets(i).source_uri,
                    format            => l_datasets(i).format,
                    operation_id      => l_opid
                    );
    
                select *
                into l_load_op_rec
                from user_load_operations
                where id = l_opid;
    
                write ('status : ' || l_load_op_rec.status, 3);
                write ('# rows : ' || l_load_op_rec.rows_loaded, 3);
    
                if not debug_on then
                    write('dropping logging tables (enable debugging to preserve logs)', 2);
                    exec('drop table ' || l_load_op_rec.logfile_table);
                    exec('drop table ' || l_load_op_rec.badfile_table);
                end if;
    
                write ('Done loading ' || l_datasets(i).table_name, 2);
            exception
                when others then
                    write(sqlerrm);
            end;
        end if; -- loading data
    end loop;
    write('Done loading tables', 1);
    
    /**
        Add constraints
    **/
    write('Adding constraints', 1);
    
    for i in 1 .. l_datasets.count
    loop
        if l_datasets(i).constraints is not null then
            write('adding constraints for table ' || l_datasets(i).table_name , 2);
            exec (l_datasets(i).constraints);
        end if;
    end loop;
    write('Done adding constraints', 1);
    
    /**
        Run post-load procedures (e.g. spatial metadata updates
    **/
    write('Run post-load procedures', 1);
    
    for i in 1 .. l_datasets.count
    loop
        if l_datasets(i).post_load_proc is not null then
            write('run post-load procedure for table ' || l_datasets(i).table_name , 2);
            exec ('begin admin.' || l_datasets(i).post_load_proc || '; end;');
        end if;
    end loop;
    write('Done post-load procedures', 1);
    
    /**
        Done.
    **/
    
    write('** Total time(mm:ss):  '
          || to_char(extract(minute from numtodsinterval(sysdate-start_time, 'DAY')), 'FM00')
          || ':'
          || to_char(extract(second from numtodsinterval(sysdate-start_time, 'DAY')), 'FM00'));
    end add_dataset;
    
    
    /* install the prerequisite procedures */
    procedure install_prerequisites as    
        l_num_scripts number;
    begin
    
    -- The setup/scripts folder contains all of the prerequisite scripts required by
    -- the labs.  Install those scripts
    write('Adding prerequisite scripts', 1);
    write('source path  = ' || install_path);
        
    
    select count(*)
    into l_num_scripts
    from dbms_cloud.list_objects (
       location_uri => install_path
      );

    
    write(l_num_scripts || ' scripts will be installed');
    
    for rec in (
        select *
        from dbms_cloud.list_objects (
           location_uri => install_path
          )
    )
    loop 
        begin
    
            write('installing ' || install_path || rec.object_name, 2);
            
            dbms_cloud_repo.install_sql (
                content         => to_clob(dbms_cloud.get_object(object_uri => install_path || rec.object_name)),
                stop_on_error   => false
                
            );

  
            exception
                when others then
                    write(sqlerrm);
    
        end;
    end loop;
    
    write('Done installing scripts', 1);
    
    end install_prerequisites;

    procedure add_adb_user(user_name varchar2, pwd varchar2) 
    as
        l_count number;
        type t_db_object is TABLE OF VARCHAR2(100);
        db_roles_privs t_db_object;
        
        begin
            -- List of roles and privs    
            db_roles_privs := t_db_object(
                            'console_developer',
                            'dcat_sync',
                            'dwrole',
                            'graph_developer',
                            'oml_developer',
                            'soda_app',
                            'connect',
                            'create analytic view',
                            'create attribute dimension',
                            'create mining model',
                            'create any index',
                            'create procedure',
                            'create sequence',
                            'create table',
                            'create trigger',
                            'create type',
                            'create view',
                            'global query rewrite',
                            'create materialized view',
                            'resource',
                            'create job',
                            'debug connect session',
                            'inherit privileges on user admin',
                            'unlimited tablespace',
                            'execute on dbms_cloud',
                            'execute on dbms_cloud_repo',
                            'execute on dbms_session',
                            'execute on dbms_soda',
                            'execute on dbms_soda_admin',                        
                            'all on directory data_pump_dir',
                            'select on sys.v_$services',
                            'select on sys.dba_rsrc_consumer_group_privs',
                            'read on all_dcat_entities',
                            'read on dcat_entities',
                            'read on all_dcat_assets',
                            'read on all_dcat_folders'
                            );
                            
                           
            -- Check if user exists.            
            select count(*)
            into l_count
            from all_users
            where upper(username) = upper(user_name);
    
            workshop.write('create user', 1);
            if l_count > 0 then
                workshop.write(user_name || ' already exists.', -1);
                return;
            end if;
            
            -- Raise exception with an error
            workshop.write('create user ' || user_name || ' identified by ####');
            execute immediate 'create user ' || user_name || ' identified by ' || pwd;
    
            -- privs
            workshop.write('grant privileges and roles', 1);
            
            for i in 1 .. db_roles_privs.count loop
                workshop.exec('grant ' || db_roles_privs(i) || ' to ' || user_name);
            
            end loop;
            
            
            workshop.exec('grant soda_app to ' || user_name || ' with delegate option');
            workshop.exec('alter user ' || user_name || ' grant connect through OML$PROXY');
            workshop.exec('alter user ' || user_name || ' grant connect through GRAPH$PROXY_USER');
            -- workshop.exec('alter user ' || user_name || ' default role connect, resource, dwrole, oml_developer, graph_developer');
                
            commit;
    
            workshop.write('TO DO', 1);
            workshop.write('Run the following as "ADMIN" in SQL Worksheet to allow your new user to use the SQL Tools', 2);
            workshop.write('begin 
                    ords_admin.enable_schema (
                        p_enabled               => TRUE,
                        p_schema                => ''' || user_name || ''',
                        p_url_mapping_type      => ''BASE_PATH'',
                        p_auto_rest_auth        => TRUE   
                    );
                    end;
                    /');
    
            EXCEPTION when others then
                workshop.write('Unable to create the user.', -1);
                workshop.write(sqlerrm);
                raise;
    
    end add_adb_user;

end workshop;
/