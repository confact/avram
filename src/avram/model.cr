require "db"
require "levenshtein"
require "./schema_enforcer"
require "./polymorphic"

abstract class Avram::Model
  include Avram::Associations
  include Avram::Polymorphic
  include Avram::SchemaEnforcer

  SETUP_STEPS = [] of Nil # types are not checked in macros
  # This setting is used to show better errors
  MACRO_CHECKS = {setup_complete: false}

  class_getter table_name

  abstract def id

  macro register_setup_step(call)
    {% if MACRO_CHECKS[:setup_complete] %}
      {% call.raise "Models have already been set up. Make sure to register set up steps before models are required." %}
    {% else %}
      {% SETUP_STEPS << call %}
    {% end %}
  end

  register_setup_step Avram::Model.setup_table_name
  register_setup_step Avram::Model.setup_initialize
  register_setup_step Avram::Model.setup_db_mapping
  register_setup_step Avram::Model.setup_getters
  register_setup_step Avram::Model.setup_column_names_method
  register_setup_step Avram::BaseQueryTemplate.setup
  register_setup_step Avram::SaveOperationTemplate.setup
  register_setup_step Avram::SchemaEnforcer.setup

  macro inherited
    COLUMNS = [] of Nil # types are not checked in macros
    ASSOCIATIONS = [] of Nil # types are not checked in macros
  end

  def_equals id, model_name

  def model_name
    self.class.name
  end

  def to_param
    id.to_s
  end

  # Reload the model with the latest information from the database
  #
  # This method will return a new model instance with the
  # latest data from the database. Note that this does
  # **not** change the original instance, so you may need to
  # assign the result to a variable or work directly with the return value.
  #
  # Example:
  #
  # ```crystal
  # user = SaveUser.create!(name: "Original")
  # SaveUser.update!(user, name: "Updated")
  #
  # # Will be "Original"
  # user.name
  # # Will return "Updated"
  # user.reload.name # Will be "Updated"
  # # Will still be "Original" since the 'user' is the same model instance.
  # user.name
  #
  # Instead re-assign the variable. Now 'name' will return "Updated" since
  # 'user' references the reloaded model.
  # user = user.reload
  # user.name
  # ```
  def reload : self
    base_query_class.find(id)
  end

  # Same as `reload` but allows passing a block to customize the query.
  #
  # This is almost always used to preload additional relationships.
  #
  # Example:
  #
  # ```crystal
  # user = SaveUser.create(params)
  #
  # # We want to display the list of articles the user has commented on, so let's #
  # # preload them to avoid N+1 performance issues
  # user = user.reload(&.preload_comments(CommentQuery.new.preload_article))
  #
  # # Now we can safely get all the comment authors
  # user.comments.map(&.article)
  # ```
  #
  # Note that the yielded query is the `BaseQuery` so it will not have any
  # methods defined on your customized query. This is usually fine since
  # typically reload only uses preloads.
  #
  # If you do need to do something more custom you can manually reload:
  #
  # ```crystal
  # user = SaveUser.create!(name: "Helen")
  # UserQuery.new.some_custom_preload_method.find(user.id)
  # ```
  def reload : self
    query = yield base_query_class.new
    query.find(id)
  end

  macro table(table_name = nil)
    {% unless table_name %}
      {% table_name = run("../run_macros/infer_table_name.cr", @type.id) %}
    {% end %}

    default_columns

    {{ yield }}

    setup({{table_name}})
    {% MACRO_CHECKS[:setup_complete] = true %}
  end

  macro primary_key(type_declaration)
    PRIMARY_KEY_TYPE = {{ type_declaration.type }}
    PRIMARY_KEY_NAME = {{ type_declaration.var }}
    column {{ type_declaration.var }} : {{ type_declaration.type }}, autogenerated: true
    alias PrimaryKeyType = {{ type_declaration.type }}

    def self.primary_key_name : Symbol
      :{{ type_declaration.var.stringify }}
    end

    def primary_key_name : Symbol
      self.class.primary_key_name
    end

    # If not using default 'id' primary key
    {% if type_declaration.var.id != "id".id %}
      # Then point 'id' to the primary key
      def id
        {{ type_declaration.var.id }}
      end
    {% end %}
  end

  macro default_columns
    primary_key id : Int64
    timestamps
  end

  macro skip_default_columns
    macro default_columns
    end
  end

  macro timestamps
    column created_at : Time, autogenerated: true
    column updated_at : Time, autogenerated: true
  end

  macro setup(table_name)
    {% table_name = table_name.id %}

    {% for step in SETUP_STEPS %}
      {{ step.id }}(
        type: {{ @type }},
        table_name: {{ table_name }},
        primary_key_type: {{ PRIMARY_KEY_TYPE }},
        primary_key_name: {{ PRIMARY_KEY_NAME }},
        columns: {{ COLUMNS }},
        associations: {{ ASSOCIATIONS }}
      )
    {% end %}
  end

  def delete
    self.class.database.run do |db|
      db.exec "DELETE FROM #{@@table_name} WHERE #{primary_key_name} = #{escape_primary_key(id)}"
    end
  end

  private def escape_primary_key(id : Int64 | Int32 | Int16)
    id
  end

  private def escape_primary_key(id : UUID)
    PG::EscapeHelper.escape_literal(id.to_s)
  end

  macro setup_table_name(table_name, *args, **named_args)
    @@table_name = :{{table_name}}
    TABLE_NAME = :{{table_name}}
  end

  macro setup_initialize(columns, *args, **named_args)
    def initialize(
        {% for column in columns %}
          @{{column[:name]}},
        {% end %}
      )
    end
  end

  # Setup [database mapping](http://crystal-lang.github.io/crystal-db/api/0.5.0/DB.html#mapping%28properties%2Cstrict%3Dtrue%29-macro) for the model's columns.
  #
  # NOTE: Avram::Migrator saves `Float` columns as numeric which need to be
  # converted from [PG::Numeric](https://github.com/will/crystal-pg/blob/master/src/pg/numeric.cr) back to `Float64` using a `convertor`
  # class.
  macro setup_db_mapping(columns, *args, **named_args)
    DB.mapping({
      {% for column in columns %}
        {{column[:name]}}: {
          {% if column[:type].id == Float64.id %}
            type: PG::Numeric,
            convertor: Float64Converter,
          {% else %}
            {% if column[:type].is_a?(Generic) %}
            type: {{column[:type]}},
            {% else %}
            type: {{column[:type]}}::Lucky::ColumnType,
            {% end %}
          {% end %}
          nilable: {{column[:nilable]}},
        },
      {% end %}
    })
  end

  module Float64Converter
    def self.from_rs(rs)
      rs.read(PG::Numeric).to_f
    end
  end

  macro setup_getters(columns, *args, **named_args)
    {% for column in columns %}
      {% db_type = column[:type].is_a?(Generic) ? column[:type].type_vars.first : column[:type] %}
      def {{column[:name]}} : {% if column[:nilable] %}::Union({{db_type}}, ::Nil){% else %}{{column[:type]}}{% end %}
        %from_db = {{ db_type }}::Lucky.from_db!(@{{column[:name]}})
        {% if column[:nilable] %}
          %from_db.as?({{db_type}})
        {% else %}
          %from_db.as({{column[:type]}})
        {% end %}
      end
      {% if column[:type].id == Bool.id %}
      def {{column[:name]}}? : Bool
        !!{{column[:name]}}
      end
      {% end %}
    {% end %}
  end

  macro column(type_declaration, autogenerated = false)
    {% if type_declaration.type.is_a?(Union) %}
      {% data_type = "#{type_declaration.type.types.first}".id %}
      {% nilable = true %}
    {% else %}
      {% data_type = "#{type_declaration.type}".id %}
      {% nilable = false %}
    {% end %}
    {% COLUMNS << {name: type_declaration.var, type: data_type, nilable: nilable.id, autogenerated: autogenerated} %}
  end

  macro setup_column_names_method(columns, *args, **named_args)
    def self.column_names : Array(Symbol)
      [
        {% for column in columns %}
          :{{column[:name]}},
        {% end %}
      ]
    end
  end

  macro association(table_name, type, relationship_type, foreign_key = nil, through = nil)
    {% ASSOCIATIONS << {type: type, table_name: table_name.id, foreign_key: foreign_key, relationship_type: relationship_type, through: through} %}
  end
end
