-- Tables/Views/UDFs used for MDL name resolution

-- Housekeeping
DROP TABLE IF EXISTS mdl_dictionaries CASCADE;

CREATE OR REPLACE FUNCTION mdl_flush () RETURNS void AS
$$
BEGIN
  NULL;
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mdl_clean () RETURNS void AS
$$
BEGIN
  DELETE FROM mdl_dictionaries;
END
$$ LANGUAGE plpgsql;

-- Preprocessed dictionary data
CREATE TABLE mdl_dictionaries (
       id serial,
       att_id integer,
       value text
);
CREATE INDEX idx_mdl_dictionaries_value ON mdl_dictionaries USING hash (value);



-- Tables/views for computing description length
-- In general DL = plogm + avgValLen*(log(alphabetSize)) 
--               + fplog maxValLen + (f/n)sum_n(sum_p(log (# vals ok /# vals possible)))
-- In our case, p = 1, m = const, alphabetSize = 128, so we get
-- DL = avgValLen*7 + f*log maxValLen + (f/n) sum_n[log(#vals ok) - log(#vals possible)]
-- Where n is size of input dict, f is fraction of values accepted,
-- and (#vals ok/#vals possible) is length specific.

CREATE VIEW mdl_dict_card_by_len AS
     SELECT att_id, length(value) l, COUNT(*) card
       FROM mdl_dictionaries
   GROUP BY att_id, l;

CREATE VIEW mdl_input_dict_stats AS
     SELECT source_id, name, COUNT(*) n,
            AVG(length(value)) avglen, MAX(length(value)) maxlen
       FROM in_data
   GROUP BY source_id, name;

CREATE VIEW mdl_input_match_counts_by_len AS
     SELECT i.source_id, i.name, d.att_id, length(i.value) l, COUNT(*) card
       FROM in_data i, mdl_dictionaries d
      WHERE i.value = d.value
   GROUP BY i.source_id, i.name, d.att_id, l;

CREATE VIEW mdl_input_match_fracs AS
     SELECT m.source_id, m.name, m.att_id, (SUM(m.card)::float / s.n::float) f
       FROM mdl_input_match_counts_by_len m, mdl_input_dict_stats s
      WHERE m.source_id = s.source_id
        AND m.name = s.name
   GROUP BY m.source_id, m.name, m.att_id, s.n;

CREATE VIEW mdl_description_length AS
     SELECT i.source_id, i.name, i.att_id,
   	    (f.f * ln(s.maxlen)) term1, (1.0 - f.f) * s.avglen * ln(128) term2,
	    (f.f / s.n::float) * SUM(ln(i.card * l.card)) term3
       	    /*(ln(128)*s.avglen) term1, (f.f * ln(s.maxlen)) term2,
	    (f.f / s.n::float) * sum(ln(l.card) - l.l * ln(128)) term3*/
       FROM mdl_input_match_counts_by_len i, mdl_input_dict_stats s,
	    mdl_input_match_fracs f, mdl_dict_card_by_len l
      WHERE i.source_id = s.source_id
	AND i.name = s.name
	AND i.source_id = f.source_id
	AND i.name = f.name
	AND i.att_id = f.att_id
	AND i.att_id = l.att_id
   GROUP BY i.source_id, i.name, i.att_id, s.avglen, s.maxlen, f.f, s.n;


-- UDF to move processed input data into MDL dictionaries.
-- Assumes name resolution is completed, i.e. attribute_clusters
-- has records for incoming data
-- NB: mdl_dictionaries may contain duplicate recs after this!
CREATE OR REPLACE FUNCTION mdl_load_dictionaries () RETURNS void AS
$$
BEGIN
  -- Add new values to dictionaries
  INSERT INTO mdl_dictionaries (att_id, value)
       SELECT a.global_id, i.value
         FROM in_data i, attribute_clusters a
        WHERE i.source_id = a.local_source_id
          AND i.name = a.local_name;
END
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION mdl_load_input () RETURNS void AS
$$
BEGIN
  NULL;
END
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION mdl_load_results () RETURNS void AS
$$
BEGIN
  CREATE INDEX idx_mdl_input_value ON in_data USING hash (value);

  INSERT INTO nr_raw_results (source_id, name, method_name, match, score)
  SELECT source_id, name, 'mdl', att_id, term1+term2+term3
    FROM mdl_description_length;

  DROP INDEX IF EXISTS idx_mdl_input_value;
END
$$ LANGUAGE plpgsql;
