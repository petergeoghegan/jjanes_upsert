create table xlogdump_records
(
  rmgr text not null,
  len_rec numeric not null,
  len_tot numeric not null,
  tx xid not null,
  r_lsn pg_lsn,
  prev_lsn pg_lsn,
  descr text not null,
  relation text
);

-- Function for conveniently viewing relation affected by entries into
-- xlogdump_records (accepts and parses pg_xlodump "descr" text):

create or replace function descr_to_name(descr text) returns text as $$
declare
  parts text[] := (select regexp_split_to_array(substring(descr, 'Y*[0-9]+\/[0-9]+\/[0-9]+'), E'\/'));
begin
  return pg_filenode_relation(parts[1]::oid, parts[3]::oid);
end;
$$ language plpgsql stable;


create function fill_in_relation() returns trigger as $fill$
begin
  new.relation := (select descr_to_name(new.descr));
  return new;
end;
$fill$ language plpgsql;

create trigger xlogdump_records_descr before insert or update on xlogdump_records
    for each row execute procedure fill_in_relation();
