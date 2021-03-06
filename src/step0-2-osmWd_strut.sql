/**
 * Structure of mais dataets and functions.
 * @dependences (file system) cp data/LI_wdDump.raw.csv /tmp
 */

CREATE EXTENSION IF NOT EXISTS file_fdw;
-- pg10 can use CREATE SERVER IF NOT EXISTS files...
CREATE SERVER files FOREIGN DATA WRAPPER file_fdw;

DROP SCHEMA IF EXISTS wdosm CASCADE;
CREATE SCHEMA wdosm;

CREATE TABLE wdosm.source (
  id serial NOT NULL PRIMARY KEY,
  abbrev text NOT NULL, -- abbrev of name
  name text,     -- region or curator's project name
  curator text,  -- the name of the collectibe responsible by checks and endorsements
  created date NOT NULL DEFAULT now(),
  info JSONb,
  UNIQUE (abbrev)
);
COMMENT ON TABLE wdosm.source IS $$Curator and source description.
Use ISO 3166-1 ALPHA-2 country codes as name abbreviations.
Each dataset is associated to region, typically a country.
The info field is generated by "osmium fileinfo -e" of original country.osm.pbf.
$$;

CREATE FUNCTION wdosm.get_sid( text DEFAULT '', text DEFAULT '', text DEFAULT '' ) RETURNS int AS $f$
  INSERT INTO wdosm.source (abbrev,name,curator) VALUES (
     (SELECT CASE WHEN $1>'' THEN $1 ELSE 'inst-test-num'||round(EXTRACT(EPOCH FROM now())*1000-153470000000)::text END)
     ,(SELECT CASE WHEN $2>'' THEN $2 ELSE 'Installation tests, CHANGE this title' END)
     ,(SELECT CASE WHEN $3>'' THEN $3 ELSE 'no-curation, CHANGE here' END)
   ) RETURNING id
  ;
$f$ language SQL strict;


CREATE TABLE wdosm.main (
  osm_type char(1) NOT NULL, -- the element-type (n=node,w=way,r=relation)
  osm_id bigint NOT NULL,  -- the OSM UNIQUE ID (global or in the osm_type namespace).
  sid int NOT NULL REFERENCES wdosm.source(id) DEFAULT 1,
  wd_id bigint,
  feature_type text,
  centroid text CHECK ( char_length(centroid)<20 ),-- old bigint, now direct GeoHash. Eg. 'u0qgbz9dns1'
  wd_member_ids JSONb,
  used_ref_ids bigint[], -- a list of valid osm_id's that generated the wd_members.
  count_origref_ids  int,  -- the total number of refs in the original member-set
  count_parseref_ids  int,  -- the total number of refs in the parsed member-set
  UNIQUE(sid,osm_type,osm_id)
);

COMMENT ON TABLE wdosm.main IS $$Main table for Wikidata-tag OSM database dump.
The uniqueness if osm_id is complemented by osm_type and, as each country can repeat borders, sid.
Is supposed that each osm_id have only one Wikidata-ID (wd_id).
Elements of osm_type "w" and "r" (ways and relations) have members.
$$;
COMMENT ON COLUMN wdosm.main.osm_type IS $$Type of OSM-element.
Can be n=node, w=way, r=relation. See https://wiki.openstreetmap.org/wiki/elements
$$;
COMMENT ON COLUMN wdosm.main.osm_type IS $$The OSM-element unique identifier in the osm_type ID-space.
Is a 64-bit non-zero positive integer (SQL int8 or bigint).
$$;
COMMENT ON COLUMN wdosm.main.wd_id IS $$The Wikidata "Q" identifier, a value of the "tag:wikidata".
Uniquely identifies the Map Feature represented by the OSM-element.
See https://wiki.openstreetmap.org/wiki/Key:wikidata
$$;
COMMENT ON COLUMN wdosm.main.feature_type IS $$The value of "tag:type" or other general tag characterization.
Is expectd that feature_type concept will be compatible with wd_id concept.
See https://github.com/OSMBrasil/simple-osmWd2csv/wiki/Associating-osmType-MdClass-by-common-ancestor
$$;
COMMENT ON COLUMN wdosm.main.centroid IS $$An approximated center of the geometry of the element.
It is a "spatial complement" of the wd_id, to group features of the same approximate location.
Based on https://en.wikipedia.org/wiki/Geohash
$$;
COMMENT ON COLUMN wdosm.main.wd_member_ids IS $$A bag of wd_ids of element-members.
Each wd_id and respective counter (number of elements with same wd_id).
$$;
COMMENT ON COLUMN wdosm.main.used_ref_ids IS $$A complement of wd_member_ids.
For fast retrieve of the list of osm_ids... Can be enconded also in the json of wd_member_ids.
$$;
COMMENT ON COLUMN wdosm.main.used_ref_ids IS $$Total number of refs in the original member-set.
Historic (log) information about original number of members.
$$;

CREATE TABLE wdosm.tmp_expanded (
  -- only TMP, no sid int NOT NULL REFERENCES wdosm.source(id) DEFAULT 1,
  osm_type char NOT NULL,
  osm_id bigint NOT NULL,
  wd_id bigint,
  ref_type char,
  ref_id bigint,  -- can be null
  UNIQUE(osm_type,osm_id,ref_type,ref_id)
);
COMMENT ON TABLE wdosm.tmp_expanded IS $$Temporary table for OSM database dump "tree analyse".
A working table, used during the parse process. The complete
$$;

-- only for data-transfer:
CREATE FOREIGN TABLE wdosm.tmp_raw_csv (
   osm_type text,
   osm_id bigint,
   other_ids text
) SERVER files OPTIONS (
   filename '/tmp/TMP.wdDump.raw.csv',
   format 'csv',
   header 'true'
);
COMMENT ON FOREIGN TABLE wdosm.tmp_raw_csv IS $$Temporary table for data-transfer, from a CSV file.
A working table, used during the loading process, in "stream mode" instead direct copy.
$$;

CREATE TABLE wdosm.tmp_raw_dist_ids (
  osm_id bigint NOT NULL PRIMARY KEY -- will create UNIQUE INDEX
);
COMMENT ON TABLE wdosm.tmp_raw_dist_ids IS $$Temporary table quality control during data-transfer.
A working table, used during the loading process, a heuristic for fast-check over valid id-references.
$$;

-- -- -- -- -- -- -- --
-- -- -- -- -- -- -- --

-- Other VIEWS (function dependents)

CREATE VIEW wdosm.vw_tmp_output AS
  SELECT sid, osm_type, osm_id
         ,'Q'||wd_id AS wd_id
         ,centroid --old base36_encode(centroid) refcenter
         ,jsonb_summable_maxval(wd_member_ids) wd_memb_max
         ,jsonb_summable_output(wd_member_ids) wd_member_ids
         ,wd_member_ids is null has_wdmembs
  FROM wdosm.main
  ORDER BY 1,2
;

-- FUNCtIONS


CREATE FUNCTION wdosm.output_to_csv (
  p_source_id int,
  p_name text DEFAULT 'TMP',
  p_expcsv boolean DEFAULT true,
  p_path text DEFAULT '/tmp'
) RETURNS text AS $f$
  DECLARE
    sql text := $$
    COPY ( -- main dump
      SELECT osm_type, osm_id, wd_id, centroid
      FROM wdosm.vw_tmp_output
      WHERE sid=%s AND wd_id is NOT null
    ) TO %L CSV HEADER;
    COPY ( -- list suspects
    SELECT osm_type, osm_id, wd_member_ids
    FROM wdosm.vw_tmp_output
    WHERE sid=%s AND wd_id is null AND has_wdmembs -- future wd_memb_max>1
  ) TO %L  CSV HEADER;
  $$;
  fname_pre text := '%s/%s';
  BEGIN
    p_name = upper(trim(p_name));
    fname_pre := format(fname_pre,p_path,p_name);
    sql := format(sql, $1, fname_pre||'.wdDump.csv', $1, fname_pre||'.noWdId.csv');
    EXECUTE sql;
    RETURN format('-- files CSVs saved, see ls %s*',fname_pre);
  END
$f$ LANGUAGE plpgsql;


CREATE or replace FUNCTION wdosm.alter_tmp_raw_csv (
  p_name text DEFAULT 'TMP', -- eg. 'LI', the ISO-two-letter code Liechtenstein
  p_run_insert boolean DEFAULT true,
  p_path text DEFAULT '/tmp'
) RETURNS text AS $f$
DECLARE
  fname text := '%s/%s.wdDump.raw.csv';
  sql text := $$
     ALTER FOREIGN TABLE wdosm.tmp_raw_csv OPTIONS (
       SET filename %L
     );
  $$;
BEGIN
  p_name = upper(trim(p_name));
  fname := format(fname,p_path,p_name);
  sql := format(sql,fname);
  IF p_run_insert THEN
    sql:=sql || $$
    DELETE FROM wdosm.tmp_raw_dist_ids;
    -- Heuristic to avoid a lot of non-existent IDs (file OSM was filtered)
    INSERT INTO  wdosm.tmp_raw_dist_ids
      SELECT DISTINCT osm_id FROM wdosm.tmp_raw_csv
    ;
    $$;
  END IF;
  EXECUTE sql;
  RETURN format('-- table wdosm.tmp_raw_csv using %L',fname);
END
$f$ LANGUAGE plpgsql;

COMMENT ON FUNCTION wdosm.alter_tmp_raw_csv(text,boolean,text) IS $$Tool for initialize this project.
Change p_path to indicate the folder of the CSV files.
$$;

-- -- -- -- -- --
-- -- -- -- -- --

CREATE FUNCTION wdosm.wd_id_group(  bigint[] ) RETURNS JSONB AS $f$
  -- convert the array[array[wd_id,osm_id]]::bigint[]
  SELECT jsonb_object_agg('Q'||x::text,n)
  -- old jsonb_summable_aggmerge( jsonb_build_object('Q'||x::text,n) )
  FROM (
    SELECT COALESCE(x[1],0) as x, count(*) as n  --, array_agg(x[2])
    FROM unnest_2d_1d(CASE WHEN $1='{}'::bigint[] THEN NULL ELSE $1 END) t(x)
    GROUP BY 1
  ) t2
$f$ language SQL strict IMMUTABLE;

CREATE FUNCTION wdosm.wd_id_group_vals(  bigint[] ) RETURNS bigint[] AS $f$
  SELECT array_agg(x)
  FROM (
    SELECT DISTINCT x[2] as x
    FROM unnest_2d_1d(CASE WHEN $1='{}'::bigint[] THEN NULL ELSE $1 END) t(x)
    WHERE x[2]>1  -- so, and not null
    GROUP BY 1
    ORDER BY 1
  ) t2
$f$ language SQL strict IMMUTABLE;


CREATE FUNCTION wdosm.get_source_abbrev( int ) RETURNS text AS $f$
  SELECT abbrev FROM wdosm.source WHERE id=$1
$f$ language SQL strict IMMUTABLE;

CREATE TABLE wdosm.kx_step1( -- for wdosm.parse_insert
    osm_type char(1), osm_id bigint, is_int boolean,
    ref_type char(1), ref text, is_ref boolean, ref2 bigint
);
CREATE INDEX expand_step1_idx1 ON wdosm.kx_step1 (osm_type, osm_id, ref_type, ref);
CREATE INDEX expand_step1_idx2 ON wdosm.kx_step1 (ref2);

CREATE FUNCTION wdosm.main_fast_ref_check(
  p_osm_type char, p_osm_id bigint
) RETURNS JSONb AS $f$
    SELECT wdosm.wd_id_group( array_agg_cat(all_refs) )
    FROM (
      SELECT DISTINCT array[wd_id,osm_id] as all_refs
      FROM wdosm.tmp_expanded e INNER JOIN (
        SELECT ref_type, ref_id
        FROM wdosm.tmp_expanded
        WHERE osm_type=p_osm_type AND osm_id=p_osm_id
      ) u ON e.osm_type=u.ref_type AND e.osm_id=u.ref_id
      WHERE e.wd_id IS NOT NULL AND e.wd_id>0
    ) t1
$f$ language SQL strict IMMUTABLE;

CREATE FUNCTION wdosm.main_update_fast(p_source_id int) RETURNS void AS $f$
  UPDATE wdosm.main
  SET  wd_member_ids = wdosm.main_fast_ref_check(osm_type,osm_id)
  WHERE sid=p_source_id
$f$ language SQL strict VOLATILE;

CREATE FUNCTION wdosm.main_update_complete(
  p_source_id int,
  p_stop_level integer DEFAULT 5
) RETURNS void AS $f$
  UPDATE wdosm.main
  SET  wd_member_ids = wdosm.wd_id_group(pairs)
      ,used_ref_ids  = array_distinct_sort(wdosm.wd_id_group_vals(pairs))
  FROM (
    WITH RECURSIVE tree as (
      SELECT osm_type,osm_id, wd_id, ref_type, ref_id,
             array[array[0,0]]::bigint[] as all_refs
      FROM wdosm.tmp_expanded
      UNION ALL
      SELECT c.osm_type, c.osm_id, c.wd_id, c.ref_type, c.ref_id
             ,p.all_refs || array[c.wd_id,c.osm_id]
             -- debug array[CASE WHEN c.wd_id IS NULL THEN 1 ELSE c.wd_id END,c.osm_id]
      FROM wdosm.tmp_expanded c JOIN tree p
        ON  c.ref_type=p.osm_type AND c.ref_id = p.osm_id AND c.osm_id!=p.osm_id
           AND array_length(p.all_refs,1)<p_stop_level -- to exclude the endless loops
    ) --end with
    SELECT osm_type, osm_id, array_agg_cat(all_refs) as pairs
    FROM (
      SELECT distinct osm_type, osm_id, all_refs
      FROM tree
      WHERE array_length(all_refs,1)>1 -- ignores initial array[0,0].
    ) t
    GROUP BY 1,2
    ORDER BY 1,2
  ) t2
  WHERE main.sid=p_source_id AND t2.osm_id=main.osm_id AND t2.osm_type=main.osm_type
$f$ language SQL strict VOLATILE;


/**
 * MAIN parse process.
 */
CREATE or replace FUNCTION wdosm.parse_insert(
  p_source_id int,  -- must greater than 0
  p_expcsv boolean DEFAULT true, -- to export CSV files
  p_delkxs boolean DEFAULT true, -- to delete caches
  p_update_method text DEFAULT 'fast',
  p_stop_level integer DEFAULT 5 -- avoid long chains membership and long CPU time.
) RETURNS text AS $f$

  DELETE FROM wdosm.kx_step1;
  INSERT INTO wdosm.kx_step1 (osm_type,osm_id,ref_type,ref,is_int,is_ref,ref2)
    SELECT DISTINCT osm_type,osm_id,ref_type,ref,is_int
           ,is_int AND ref_type NOT IN ('Q','c') is_ref
           ,CASE WHEN is_int THEN ref::bigint ELSE NULL END ref2
    FROM (
      SELECT *, (sref ~ '^[a-zA-Z][0-9]+$') as is_int
             ,substr(sref,1,1) as ref_type
             ,substr(sref,2) as ref
      FROM (
        SELECT substr(osm_type,1,1)::char osm_type
          ,osm_id::bigint as osm_id
          ,regexp_split_to_table(other_ids, '[\s,;:\-]+') as sref
        FROM wdosm.tmp_raw_csv
      ) t3
    ) t2
  ;
  DELETE FROM wdosm.main WHERE sid=p_source_id;  -- caution!!
  INSERT INTO wdosm.main (osm_type,osm_id,sid,wd_id,feature_type,centroid,count_origref_ids,count_parseref_ids)
    SELECT osm_type, osm_id, p_source_id
      ,MAX(wd_id)  FILTER(WHERE ref_type='Q') wd_id -- (redundance: remove filter)
      ,array_to_string(array_agg(other) FILTER(WHERE ref_type='t' OR ref_type='h'),'-') feature_type
      ,MAX(centroid)  centroid
      --,NULL::jsonb wd_member_ids -- for a second-step
      --,NULL::bigint[] used_osm_members -- for a second-step
      ,SUM(count_ref_ids) count_origref_ids -- original from file.OSM or pre-parser
      ,SUM(array_length(ref_ids,1)) count_parseref_ids -- as useful ref_ids
    FROM (
      SELECT osm_type, osm_id, ref_type
        ,SUM(CASE WHEN is_ref THEN 1::int ELSE 0::int END)  count_ref_ids -- see also n
        ,array_distinct_sort( array_agg(ref2) FILTER (
          WHERE is_ref AND ref2 IN (SELECT osm_id FROM wdosm.tmp_raw_dist_ids)
        )) ref_ids -- array_length(ref_ids,1) =< count_ref_ids
        ,MAX(ref)  FILTER( WHERE not(is_ref) AND ref_type NOT IN ('Q','c') ) other
        ,MAX(ref) FILTER( WHERE ref_type='c' ) centroid
        ,MAX(ref2) FILTER( WHERE ref_type='Q' AND is_int ) wd_id
        ,COUNT(*)::int as n -- for quality-control only; n=count_ref_ids always excet nodes (count_ref_ids=0 and n=1)
      FROM wdosm.kx_step1
      GROUP BY 1,2,3
      ORDER BY 1,2,3
    ) t0
    GROUP BY 1,2
    ORDER BY 1,2
  ;
  DELETE FROM wdosm.tmp_expanded;
  INSERT INTO wdosm.tmp_expanded (osm_type, osm_id, wd_id, ref_type, ref_id)
      SELECT DISTINCT m.osm_type, m.osm_id, m.wd_id, s.ref_type, s.ref2
      FROM wdosm.kx_step1 s INNER JOIN wdosm.main m
        ON m.sid=p_source_id AND m.osm_type=s.osm_type AND m.osm_id=s.osm_id
        -- AND ref_type IN ('n','w','r')
      WHERE s.is_ref AND s.ref2 IN (SELECT osm_id FROM wdosm.tmp_raw_dist_ids)
      -- GROUP BY 1,2,3,4
      ORDER BY 1,2,3,4,5  -- not need
  ;

  DELETE FROM wdosm.kx_step1 WHERE p_delkxs;

  SELECT CASE  -- dependents on tmp_expanded and updates wdosm.main
    WHEN p_update_method='fast' THEN wdosm.main_update_fast(p_source_id)
    ELSE wdosm.main_update_complete(p_source_id,p_stop_level)
  END;

  UPDATE wdosm.main SET wd_member_ids=NULL WHERE jsonb_typeof(wd_member_ids)='null';
  UPDATE wdosm.main SET used_ref_ids=NULL  WHERE used_ref_ids='{}'::bigint[];

  DELETE FROM wdosm.tmp_expanded WHERE p_delkxs;

  SELECT wdosm.output_to_csv(p_source_id,'TMP'); -- WHERE p_expcsv;  -- retorno da funcao

$f$ LANGUAGE SQL VOLATILE;

---- --- ---

SELECT wdosm.alter_tmp_raw_csv('LI',false) AS fake_load_trash;
-- LI is a sample, step3 will use correct.
