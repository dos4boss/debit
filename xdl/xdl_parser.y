/*
 * (C) Copyright 2006 Jean-Baptiste Note <jean-baptiste.note@m4x.org>
 * All rights reserved.
 */

/* XDL Parser */

%{

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "parser.h"
#include "wiring.h"
#include "debitlog.h"
/* XXX */
#include "design_v2.h"

#define YYPARSE_PARAM yyparm
#define YYDEBUG 1

void yyerror(char *err) {
  debit_log(L_PARSER, "XDL parser error: %s", err);
}

/* could be changed, depending on whether the lexer is reentrant */
extern int yylex(void *yylval_param);

/*
 * Type of interpretation for the identifier. This information is passed
 * back to the lexer in case we need to interpret identifiers.
 */
typedef enum ident_type_t {
  IDENT_TYPE_STRING = 0,
  IDENT_TYPE_WIRE,
  IDENT_TYPE_SITE,
} ident_type_t;

static int write_pip(parser_t *parser,
		     const sited_pip_t spip) {
  const wire_db_t *wdb = parser->pipdb->wiredb;
  const chip_descr_t *chip = parser->chip;
/*   const csite_descr_t *csite = get_site(chip, spip.site); */
  int err = 0;
  const unsigned *cfgbits;
  size_t nbits;
  uint32_t vals;
  char pname[64];
  (void) snprint_spip(pname, sizeof(pname), wdb, chip, &spip);
  debit_log(L_PARSER, "%s", pname);

  /* lookup the pip in the database */
  err = bitpip_lookup(spip, chip, parser->pipdb,
		      &cfgbits, &nbits, &vals);
  if (err) {
    debit_log(L_PARSER, "Error: unknown sited pip %s", pname);
    return err;
  }

  /* process the bitstream accordingly */
/*   set_bitstream_site_bits(bitstream->bit, csite, vals, cfgbits, nbits); */
  return err;
}


static void treat_pip(parser_t *parser,
		      const char *start,
		      const char *end,
		      const char *site) {
  const wire_db_t *wdb = parser->pipdb->wiredb;
  const chip_descr_t *chip = parser->chip;
  sited_pip_t spip;
  int err;
  parser->pip_counter++;

  /* Obviously this parsing should be factored in
     the lexer, before we even have to duplicate and pass strings
     around */
  err = parse_wire_simple(wdb, &spip.pip.source, start);
  if (err) {
    debit_log(L_PARSER, "unknown wire %s @%s", start, site);
    goto out_err;
  }
  err = parse_wire_simple(wdb, &spip.pip.target, end);
  if (err) {
    debit_log(L_PARSER, "unknown wire %s @%s", end, site);
    goto out_err;
  }
  err = parse_site_simple(chip, &spip.site, site);
  if (err) {
    debit_log(L_PARSER, "unknown site %s", site);
    goto out_err;
  }

  (void) write_pip(parser, spip);

 out_err:
  return;
}

#include <time.h>
static void treat_time(parsed_header_t *header) {
  static const char *date = "2006/11/ 5";
  static const char *time = "11: 4:42";
  write_option(header, BUILD_DATE, date, strlen(date));
  write_option(header, BUILD_TIME, time, strlen(time));
}

static int treat_design(parser_t *parser,
			const char *design_name,
			const char *device) {
  const char *datadir = parser->datadir;
  parsed_header_t *header = &parser->bit.header;
  bitstream_parsed_t *bit = &parser->bit;
  const chip_struct_t *chip_struct;
  int err;

  /* Fill in the pseudo-header, to be used by the bitstream writer */
  treat_time(header);
  write_option(header, FILENAME, design_name, strlen(design_name));
  write_option(header, DEVICE_TYPE, device, strlen(device));
  debit_log(L_PARSER, "Design %s on device %s\n", design_name, device);

  /* Parse device name and allocate bitstream */
  err = alloc_wbitstream(bit);
  if (err) {
    g_warning("Could not parse device name %s", device);
    return -1;
  }

  /* Load the wire/pip dbs, using the bitstream type */
  chip_struct = bit->chip_struct;
  parser->pipdb = get_pipdb(datadir);
  parser->chip = get_chip(datadir, chip_struct->chip);
  return 0;
}

%}

/* Options */
%pure-parser

%union {
  char *name;
  uint64_t val;
}

/* Bison declaration */
%token STRING
%token IDENTIFIER
%token VERSION
%token DESIGN

%token LUTID

%token INSTANCE
%token PLACED
%token UNPLACED
%token TOK_QUOTE
%token TOK_CFG_SEP
%token TOK_WS

%token NET
%token INPIN
%token OUTPIN
%token PIP
%token CONFIG
%token CONNECTION

%token TOK_E_VAL
%left '+' '*' '@'
%left NEG

%type <name> LUTID
%type <name> IDENTIFIER
%type <name> wire0
%type <name> wire1
%type <name> tile
%type <name> part
%type <name> device
%type <name> STRING
%type <name> design_name

%type <val> TOK_E_VAL
%type <val> lutexpr
%type <val> cfglut

%% /* Grammar follows */

input:   /* empty */
       | design instancelist netlist
;

/* Xilinx file format is really dumb... the comas are not even handled */
/* properly. And i'm not gonna change that. */

/* Design */
design_name: STRING ;
part: IDENTIFIER ;
ncd_version: VERSION ;

device: IDENTIFIER ;
package: IDENTIFIER ;
speed: IDENTIFIER ;

design_header: DESIGN design_name part ncd_version { treat_design(yyparm, $2, $3); }
| DESIGN design_name device package speed ncd_version { treat_design(yyparm, $2, $3); } ;

design: design_header ',' config ';' ;

/* Instances */
name: STRING ;
sitedef: STRING ;
tile: IDENTIFIER { $$ = $1; } ;
site: IDENTIFIER ;

cfgattr: IDENTIFIER { debit_log(L_PARSER, "Attribute %s", $1); } ;
cfgval:  | IDENTIFIER { debit_log(L_PARSER, "Config val %s", $1); } ; /* Configuration values / names can be empty (MUXF) */
whitespace: | TOK_WS ;  /* Whitespace can be empty */

cfgtrait: TOK_CFG_SEP cfgval;
cfglut: TOK_CFG_SEP lutexpr { $$ = $2; };
cfgvallist: cfgtrait | cfgvallist cfgtrait ;
cfgitem: cfgattr cfgvallist
| cfgattr cfgvallist cfglut { debit_log(L_PARSER, "LUT cfg %04x seen\n", (uint16_t)$3); };

cfglist: cfgitem | cfglist TOK_WS cfgitem ;
cfgstring: TOK_QUOTE whitespace cfglist whitespace TOK_QUOTE ;
placement: PLACED tile site | UNPLACED ;
config: CONFIG cfgstring ;
instance: INSTANCE name sitedef ',' placement ',' config ';' ;

instancelist: instance | instancelist instance;

/* Nets */
inst_name: STRING ;
inst_pin: IDENTIFIER ;
outpin: OUTPIN inst_name inst_pin ',' ;
inpin: INPIN inst_name inst_pin ',' ;
inpinlist: inpin | inpinlist inpin ;
iopinlist: outpin inpinlist ;

wire0: IDENTIFIER { $$ = $1; };
wire1: IDENTIFIER { $$ = $1; };
dir: CONNECTION;
pip: PIP tile wire0 dir wire1 ',' {
	treat_pip(yyparm, $3, $5, $2);
	free($3); free($5); free($2);
 } ;
piplist: pip | piplist pip ;

/* Some nets have the vcc qualifier appended after the name */
qualifier:
   | IDENTIFIER ;
net_header: NET STRING qualifier ;
net: net_header ',' iopinlist piplist ';'
   | net_header ',' config ',' ';' ;

netlist: net | netlist net ;

/* LUT expressions */
lutexpr: TOK_E_VAL               { $$ = $1; };
| lutexpr '*' lutexpr            { $$ = $1 & $3; };
| lutexpr '+' lutexpr            { $$ = $1 | $3; };
| lutexpr '@' lutexpr            { $$ = $1 ^ $3; };
| '~' lutexpr %prec NEG          { $$ = ~ $2; };
| '(' lutexpr ')'                { $$ = $2; };