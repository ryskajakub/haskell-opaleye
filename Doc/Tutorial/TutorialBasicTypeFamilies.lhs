> {-# LANGUAGE FlexibleContexts #-}
> {-# LANGUAGE FlexibleInstances #-}
> {-# LANGUAGE MultiParamTypeClasses #-}
> {-# LANGUAGE UndecidableInstances #-}
> {-# LANGUAGE TypeFamilies #-}
> {-# LANGUAGE EmptyDataDecls #-}
>
> module TutorialBasicTypeFamilies where
>
> import           Prelude hiding (sum)
>
> import           Opaleye (Column, Nullable,
>                          Table(Table), required, queryTable,
>                          Query, (.==), aggregate, groupBy,
>                          count, avg, sum, leftJoin, runQuery,
>                          showSqlForPostgres, Unpackspec,
>                          PGInt4, PGInt8, PGText, PGDate, PGFloat8)
>
> import           Control.Applicative     ((<$>), (<*>), Applicative)
>
> import qualified Data.Profunctor         as P
> import           Data.Profunctor.Product (p3)
> import           Data.Profunctor.Product.Default (Default)
> import qualified Data.Profunctor.Product.Default as D
> import           Data.Time.Calendar (Day)
>
> import qualified Database.PostgreSQL.Simple as PGS

Introduction
============

In this example file I'll give you a brief introduction to the Opaleye
relational query EDSL.  I'll show you how to define tables in Opaleye;
use them to generate selects, joins and filters; use the API of
Opaleye to make your queries more composable; and finally run the
queries on Postgres.

Schema
======

Opaleye assumes that a Postgres database already exists.  Currently
there is no support for creating databases or tables, though these
features may be added later according to demand.

A table is defined with the `Table` constructor.  The syntax is
simple.  You specify the types of the columns, the name of the table
and the names of the columns in the underlying database, and whether
the columns are required or optional.

(Note: This simple syntax is supported by an extra combinator that
describes the shape of the container that you are storing the columns
in.  In the first example we are using a tuple of size 3 and the
combinator is called `p3`.  We'll see examples of others later.)

The `Table` type constructor has two arguments.  The first one tells
us what columns we can write to the table and the second what columns
we can read from the table.  In this document we will always make all
columns required, so the write and read types will be the same.  All
`Table` types will have the same type argument repeated twice.  In the
manipulation tutorial you can see an example of when they might differ.

> personTable :: Table (Column PGText, Column PGInt4, Column PGText)
>                      (Column PGText, Column PGInt4, Column PGText)
> personTable = Table "personTable" (p3 ( required "name"
>                                       , required "age"
>                                       , required "address" ))

By default, the table `"personTable"` is looked up in PostgreSQL's
default `"public"` schema. If we wanted to specify a different schema we
could have used the `TableWithSchema` constructor instead of `Table`.

To query a table we use `queryTable`.

(Here and in a few other places in Opaleye there is some typeclass
magic going on behind the scenes to reduce boilerplate.  However, you
never *have* to use typeclasses.  All the magic that typeclasses do is
also available by explicitly passing in the "typeclass dictionary".
For this example file we will always use the typeclass versions
because they are simpler to read and the typeclass magic is
essentially invisible.)

> personQuery :: Query (Column PGText, Column PGInt4, Column PGText)
> personQuery = queryTable personTable

A `Query` corresponds to an SQL SELECT that we can run.  Here is the
SQL generated for `personQuery`.

ghci> printSql personQuery
SELECT name0_1 as result1,
       age1_1 as result2,
       address2_1 as result3
FROM (SELECT *
      FROM (SELECT name as name0_1,
                   age as age1_1,
                   address as address2_1
            FROM personTable as T1) as T1) as T1

This SQL is functionally equivalent to the following "idealized" SQL.
In this document every example of SQL generated by Opaleye will be
followed by an "idealized" equivalent version.  This will give you
some idea of how readable the SQL generated by Opaleye is.  Eventually
Opaleye should generate SQL closer to the "idealized" version, but
that is an ongoing project.  Since Postgres has a sensible query
optimization engine there should be little difference in performance
between Opaleye's version and the ideal.  Please submit any
differences encountered in practice as an Opaleye bug.

SELECT name,
       age
       address
FROM personTable

(`printSQL` is just a convenient utility function for the purposes of
this example file.  See below for its definition.)


Record types
------------

Opaleye can use user defined types such as record types in queries.

Contrary to popular belief, you don't have to define your data types
to be polymorphic in all their fields.  In fact there's a nice scheme
using type families that reduces boiler plate and has always been
compatible with Opaleye!

> type family Field      f a b n
> type family TableField f a b n req
>
> data H
> data O
> data Nulls
> data W
>
> data NN
> data N
>
> data Req
> data Opt
> 
> type instance Field H h o NN = h
> type instance Field H h o N  = Maybe h
> type instance Field O h o NN = Column o
> type instance Field O h o N  = Column (Nullable o)
>
> type instance TableField H     h o n b   = Field H h o n
> type instance TableField O     h o n b   = Field O h o n
> type instance TableField W     h o n Req = Field O h o n
> type instance TableField W     h o n Opt = Maybe (Field O h o n)
> type instance TableField Nulls h o n b   = Column (Nullable o)
>
> data Birthday f = Birthday { bdName :: TableField f String PGText NN Req
>                            , bdDay  :: TableField f Day    PGDate NN Req
>                            }
>
> instance ( Applicative (p (Birthday a))
>          , P.Profunctor p
>          , Default p (TableField a String PGText NN Req) (TableField b String PGText NN Req)
>          , Default p (TableField a Day    PGDate NN Req) (TableField b Day    PGDate NN Req)) =>
>   Default p (Birthday a) (Birthday b) where
>   def = Birthday <$> P.lmap bdName D.def
>                  <*> P.lmap bdDay  D.def

Then we can use 'Table' to make a table on our record type in exactly
the same way as before.

> birthdayTable :: Table (Birthday O) (Birthday O)
> birthdayTable = Table "birthdayTable"
>                        (Birthday <$> P.lmap bdName (required "name")
>                                  <*> P.lmap bdDay  (required "birthday"))
>
> birthdayQuery :: Query (Birthday O)
> birthdayQuery = queryTable birthdayTable

ghci> printSql birthdayQuery
SELECT name0_1 as result1,
       birthday1_1 as result2
FROM (SELECT *
      FROM (SELECT name as name0_1,
                   birthday as birthday1_1
            FROM birthdayTable as T1) as T1) as T1

Idealized SQL:

SELECT name,
       birthday
FROM birthdayTable


Aggregation
===========

Type safe aggregation is the jewel in the crown of Opaleye.  Even SQL
generating APIs which are otherwise type safe often fall down when it
comes to aggregation.  If you want to find holes in the type system of
an SQL generating language, aggregation is the best place to look!  By
contrast, Opaleye aggregations always generate meaningful SQL.

By way of example, suppose we have a widget table which contains the
style, color, location, quantity and radius of widgets.  We can model
this information with the following datatype.

> data Widget f = Widget { style    :: Field f String PGText   NN
>                        , color    :: Field f String PGText   NN
>                        , location :: Field f String PGText   NN
>                        , quantity :: Field f Int    PGInt4   NN
>                        , radius   :: Field f Double PGFloat8 NN
>                        }
>
> instance ( Applicative (p (Widget a))
>          , P.Profunctor p
>          , Default p (Field a String PGText NN)   (Field b String PGText NN)
>          , Default p (Field a Int    PGInt4 NN)   (Field b Int    PGInt4 NN)
>          , Default p (Field a Double PGFloat8 NN) (Field b Double PGFloat8 NN)
>          , Default p (Field a Day    PGDate NN)   (Field b Day    PGDate NN)) =>
>   Default p (Widget a) (Widget b) where
>   def = Widget <$> P.lmap style    D.def
>                <*> P.lmap color    D.def
>                <*> P.lmap location D.def
>                <*> P.lmap quantity D.def
>                <*> P.lmap radius   D.def

For the purposes of this example the style, color and location will be
strings, but in practice they might have been a different data type.

> widgetTable :: Table (Widget O) (Widget O)
> widgetTable = Table "widgetTable"
>                      (Widget <$> P.lmap style    (required "style")
>                              <*> P.lmap color    (required "color")
>                              <*> P.lmap location (required "location")
>                              <*> P.lmap quantity (required "quantity")
>                              <*> P.lmap radius   (required "radius"))


Say we want to group by the style and color of widgets, calculating
how many (possibly duplicated) locations there are, the total number
of such widgets and their average radius.  `aggregateWidgets` shows us
how to do this.

> aggregateWidgets :: Query (Column PGText, Column PGText, Column PGInt8,
>                            Column PGInt4, Column PGFloat8)
> aggregateWidgets = aggregate ((,,,,) <$> P.lmap style    groupBy
>                                      <*> P.lmap color    groupBy
>                                      <*> P.lmap location count
>                                      <*> P.lmap quantity sum
>                                      <*> P.lmap radius   avg)
>                              (queryTable widgetTable)

The generated SQL is

ghci> printSql aggregateWidgets
SELECT result0_2 as result1,
       result1_2 as result2,
       result2_2 as result3,
       result3_2 as result4,
       result4_2 as result5
FROM (SELECT *
      FROM (SELECT style0_1 as result0_2,
                   color1_1 as result1_2,
                   COUNT(location2_1) as result2_2,
                   SUM(quantity3_1) as result3_2,
                   AVG(radius4_1) as result4_2
            FROM (SELECT *
                  FROM (SELECT style as style0_1,
                               color as color1_1,
                               location as location2_1,
                               quantity as quantity3_1,
                               radius as radius4_1
                        FROM widgetTable as T1) as T1) as T1
            GROUP BY style0_1,
                     color1_1) as T1) as T1

Idealized SQL:

SELECT style,
       color,
       COUNT(location),
       SUM(quantity),
       AVG(radius)
FROM widgetTable
GROUP BY style, color

Note: In `widgetTable` and `aggregateWidgets` we see more explicit
uses of our Template Haskell derived code.  We use the 'pWidget'
"adaptor" to specify how columns are aggregated.  Note that this is
yet another example of avoiding a headache by keeping your datatype
fully polymorphic, because the 'count' aggregator changes a 'Wire
String' into a 'Wire Int64'.

Outer join
==========

Opaleye supports left joins.  (Full outer joins and right joins are
left to be added as a simple starter project for a new Opaleye
contributer!)

Because left joins can change non-nullable columns into nullable
columns we have to make sure the type of the output supports
nullability.  We introduce the following type synonym for this
purpose, which is just a notational convenience.

A left join is expressed by specifying the two tables to join and the
join condition.

> personBirthdayLeftJoin :: Query ((Column PGText, Column PGInt4, Column PGText),
>                                  Birthday Nulls)
> personBirthdayLeftJoin = leftJoin personQuery birthdayQuery eqName
>     where eqName ((name, _, _), birthdayRow) = name .== bdName birthdayRow

The generated SQL is

ghci> printSql personBirthdayLeftJoin
SELECT result1_0_3 as result1,
       result1_1_3 as result2,
       result1_2_3 as result3,
       result2_0_3 as result4,
       result2_1_3 as result5
FROM (SELECT *
      FROM (SELECT name0_1 as result1_0_3,
                   age1_1 as result1_1_3,
                   address2_1 as result1_2_3,
                   name0_2 as result2_0_3,
                   birthday1_2 as result2_1_3
            FROM
            (SELECT *
             FROM (SELECT name as name0_1,
                          age as age1_1,
                          address as address2_1
                   FROM personTable as T1) as T1) as T1
            LEFT OUTER JOIN
            (SELECT *
             FROM (SELECT name as name0_2,
                          birthday as birthday1_2
                   FROM birthdayTable as T1) as T1) as T2
            ON
            (name0_1) = (name0_2)) as T1) as T1

Idealized SQL:

SELECT name0,
       age0,
       address0,
       name1,
       birthday1
FROM (SELECT name as name0,
             age as age0,
             address as address0
      FROM personTable) as T1
     LEFT OUTER JOIN
     (SELECT name as name1,
             birthday as birthday1
      FROM birthdayTable) as T1
ON name0 = name1


A comment about type signatures
-------------------------------

We mentioned that Opaleye uses typeclass magic behind the scenes to
avoid boilerplate.  One consequence of this is that the compiler
cannot infer types in some cases. Use of `leftJoin` is one of those
cases.  You will generally need to provide a type signature yourself.
If you see the compiler complain that it cannot determine a `Default`
instance then specify more types.


Running queries on Postgres
===========================


Opaleye provides simple facilities for running queries on Postgres.
`runQuery` is a typeclass polymorphic function that effectively has
the following type

> -- runQuery :: Database.PostgreSQL.Simple.Connection
> --          -> Query columns -> IO [haskells]

It converts a "record" of Opaleye columns to a list of "records" of
Haskell values.  Like `leftJoin` this particular formulation uses
typeclasses so please put type signatures on everything in sight to
minimize the number of confusing error messages!

> runBirthdayQuery :: PGS.Connection
>                  -> Query (Birthday O)
>                  -> IO [Birthday H]
> runBirthdayQuery = runQuery

Conclusion
==========

There ends the Opaleye introductions module.  Please send me your questions!

Utilities
=========

This is a little utility function to help with printing generated SQL.

> printSql :: Default Unpackspec a a => Query a -> IO ()
> printSql = putStrLn . maybe "Empty query" id . showSqlForPostgres
