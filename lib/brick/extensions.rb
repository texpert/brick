# frozen_string_literal: true

# Some future enhancement ideas:

# Have markers on HM relationships to indicate "load this one every time" or "lazy load it" or "don't bother"
# Others on BT to indicate "this is a lookup"

# Mark specific tables as being lookups and they get put on the main screen as an editable thing
# If they relate to multiple different things (like looking up countries or something) then they only get edited from the main page, and importing new addresses can create a new country if needed.
# Indications of how relationships should operate will be useful soon (lookup is one kind, but probably more other kinds like this stuff makes a table or makes a list or who knows what.)
# Security must happen now -- at the model level, really low AR level automatically applied.

# Similar to .includes or .joins or something, bring in all records related through a HM, and include them in a trim way in a block of JSON
# Javascript thing that automatically makes nested table things from a block of hierarchical data (maybe sorta use one dimension of the crosstab thing)

# Finally incorporate the crosstab so that many dimensions can be set up as columns or rows and be made editable.

# X or Y axis can be made as driven by either columns or a row of data, so traditional table or crosstab can be shown, or a hybrid kind of thing of the two.

# Sensitive stuff -- make a lock icon thing so people don't accidentally edit stuff

# Static text that can go on pages - headings and footers and whatever
# Eventually some indication about if it should be a paginated table / unpaginated / a list of just some fields / columns shown in a different sequence / etc

# Grid where each cell is one field and then when you mouse over then it shows a popup other table of detail inside

# DSL that describes the rows / columns and then what each cell can have, which could be nested related data, the specifics of X and Y driving things in the cell definition like a formula

# colour coded origins

# Drag something like HierModel#name onto the rows and have it automatically add five columns -- where type=zone / where type = section / etc

# Support for Postgres / MySQL enums (add enum to model, use model enums to make a drop-down in the UI)

# Currently quadrupling up routes

# Modal pop-up things for editing large text / date ranges / hierarchies of data

# For recognised self-references, have the show page display all related objects up to the parent (or the start of a circular reference)

# ==========================================================
# Dynamically create model or controller classes when needed
# ==========================================================

# By default all models indicate that they are not views
module Arel
  class Table
    def _arel_table_type
      # AR < 4.2 doesn't have type_caster at all, so rely on an instance variable getting set
      # AR 4.2 - 5.1 have buggy type_caster entries for the root node
      instance_variable_get(:@_arel_table_type) ||
      # 5.2-7.0 does type_caster just fine, no bugs there, but the property with the type differs:
      # 5.2 has "types" as public, 6.0 "types" as private, and >= 6.1 "klass" as private.
      ((tc = send(:type_caster)) && tc.instance_variable_get(:@types)) ||
      tc.send(:klass)
    end
  end
end

module ActiveRecord
  class Base
    def self._assoc_names
      @_assoc_names ||= {}
    end

    def self.is_view?
      false
    end

    def self._brick_primary_key(relation = nil)
      return instance_variable_get(:@_brick_primary_key) if instance_variable_defined?(:@_brick_primary_key)

      pk = begin
             primary_key.is_a?(String) ? [primary_key] : primary_key || []
           rescue
             []
           end
      # Just return [] if we're missing any part of the primary key.  (PK is usually just "id")
      if relation && pk.present?
        @_brick_primary_key ||= pk.any? { |pk_part| !relation[:cols].key?(pk_part) } ? [] : pk
      else # No definitive key yet, so return what we can without setting the instance variable
        pk
      end
    end

    # Used to show a little prettier name for an object
    def self.brick_get_dsl
      # If there's no DSL yet specified, just try to find the first usable column on this model
      unless (dsl = ::Brick.config.model_descrips[name])
        descrip_col = (columns.map(&:name) - _brick_get_fks -
                      (::Brick.config.metadata_columns || []) -
                      [primary_key]).first
        dsl = ::Brick.config.model_descrips[name] = if descrip_col
                                                      "[#{descrip_col}]"
                                                    elsif (pk_parts = self.primary_key.is_a?(Array) ? self.primary_key : [self.primary_key])
                                                      "#{name} ##{pk_parts.map { |pk_part| "[#{pk_part}]" }.join(', ')}"
                                                    end
      end
      dsl
    end

    def self.brick_parse_dsl(build_array = nil, prefix = [], translations = {}, is_polymorphic = false)
      build_array = ::Brick::JoinArray.new.tap { |ary| ary.replace([build_array]) } if build_array.is_a?(::Brick::JoinHash)
      build_array = ::Brick::JoinArray.new unless build_array.nil? || build_array.is_a?(Array)
      members = []
      bracket_name = nil
      prefix = [prefix] unless prefix.is_a?(Array)
      if (dsl = ::Brick.config.model_descrips[name] || brick_get_dsl)
        klass = nil
        dsl.each_char do |ch|
          if bracket_name
            if ch == ']' # Time to process a bracketed thing?
              parts = bracket_name.split('.')
              first_parts = parts[0..-2].map do |part|
                klass = (orig_class = klass).reflect_on_association(part_sym = part.to_sym)&.klass
                puts "Couldn't reference #{orig_class.name}##{part} that's part of the DSL \"#{dsl}\"." if klass.nil?
                part_sym
              end
              parts = prefix + first_parts + [parts[-1]]
              if parts.length > 1
                unless is_polymorphic
                  s = build_array
                  parts[0..-3].each { |v| s = s[v.to_sym] }
                  s[parts[-2]] = nil # unless parts[-2].empty? # Using []= will "hydrate" any missing part(s) in our whole series
                end
                translations[parts[0..-2].join('.')] = klass
              end
              members << parts
              bracket_name = nil
            else
              bracket_name << ch
            end
          elsif ch == '['
            bracket_name = +''
            klass = self
          end
        end
      else # With no DSL available, still put this prefix into the JoinArray so we can get primary key (ID) info from this table
        x = prefix.each_with_object(build_array) { |v, s| s[v.to_sym] }
        x[prefix.last] = nil unless prefix.empty? # Using []= will "hydrate" any missing part(s) in our whole series
      end
      members
    end

    # If available, parse simple DSL attached to a model in order to provide a friendlier name.
    # Object property names can be referenced in square brackets like this:
    # { 'User' => '[profile.firstname] [profile.lastname]' }
    def brick_descrip(data = nil, pk_alias = nil)
      self.class.brick_descrip(self, data, pk_alias)
    end

    def self.brick_descrip(obj, data = nil, pk_alias = nil)
      if (dsl = ::Brick.config.model_descrips[(klass = self).name] || klass.brick_get_dsl)
        idx = -1
        caches = {}
        output = +''
        is_brackets_have_content = false
        bracket_name = nil
        dsl.each_char do |ch|
          if bracket_name
            if ch == ']' # Time to process a bracketed thing?
              datum = if data
                        data[idx += 1].to_s
                      else
                        obj_name = +''
                        this_obj = obj
                        bracket_name.split('.').each do |part|
                          obj_name += ".#{part}"
                          this_obj = caches.fetch(obj_name) { caches[obj_name] = this_obj&.send(part.to_sym) }
                          break if this_obj.nil?
                        end
                        this_obj&.to_s || ''
                      end
              is_brackets_have_content = true unless (datum).blank?
              output << (datum || '')
              bracket_name = nil
            else
              bracket_name << ch
            end
          elsif ch == '['
            bracket_name = +''
          else
            output << ch
          end
        end
        output += bracket_name if bracket_name
      end
      if is_brackets_have_content
        output
      elsif (pk_alias ||= primary_key)
        pk_alias = [pk_alias] unless pk_alias.is_a?(Array)
        id = []
        pk_alias.each do |pk_alias_part|
          if (pk_part = obj.send(pk_alias_part))
            id << pk_part
          end
        end
        if id.present?
          "#{klass.name} ##{id.join(', ')}"
        end
      else
        obj.to_s
      end
    end

    def self.bt_link(assoc_name)
      model_underscore = name.underscore
      assoc_name = CGI.escapeHTML(assoc_name.to_s)
      model_path = Rails.application.routes.url_helpers.send("#{model_underscore.tr('/', '_').pluralize}_path".to_sym)
      av_class = Class.new.extend(ActionView::Helpers::UrlHelper)
      av_class.extend(ActionView::Helpers::TagHelper) if ActionView.version < ::Gem::Version.new('7')
      link = av_class.link_to(name, model_path)
      model_underscore == assoc_name ? link : "#{assoc_name}-#{link}".html_safe
    end

    def self.brick_import_template
      template = constants.include?(:IMPORT_TEMPLATE) ? self::IMPORT_TEMPLATE : suggest_template(false, false, 0)
      # Add the primary key to the template as being unique (unless it's already there)
      template[:uniques] = [pk = primary_key.to_sym]
      template[:all].unshift(pk) unless template[:all].include?(pk)
      template
    end

    class << self
      # belongs_to DSL descriptions
      def _br_bt_descrip
        @_br_bt_descrip ||= {}
      end
      # has_many count definitions
      def _br_hm_counts
        @_br_hm_counts ||= {}
      end
      # has_many :through associative tables
      def _br_associatives
        @_br_associatives ||= {}
      end
    end

    # Search for BT, HM, and HMT DSL stuff
    def self._brick_calculate_bts_hms(translations, join_array)
      bts, hms, associatives = ::Brick.get_bts_and_hms(self)
      bts.each do |_k, bt|
        next if bt[2] # Polymorphic?

        # join_array will receive this relation name when calling #brick_parse_dsl
        _br_bt_descrip[bt.first] = if bt[1].is_a?(Array)
                                     bt[1].each_with_object({}) { |bt_class, s| s[bt_class] = bt_class.brick_parse_dsl(join_array, bt.first, translations, true) }
                                   else
                                     { bt.last => bt[1].brick_parse_dsl(join_array, bt.first, translations) }
                                   end
      end
      skip_klass_hms = ::Brick.config.skip_index_hms[self.name] || {}
      hms.each do |k, hm|
        next if skip_klass_hms.key?(k)

        if hm.macro == :has_one
          # For our purposes a :has_one is similar enough to a :belongs_to that we can just join forces
          _br_bt_descrip[k] = { hm.klass => hm.klass.brick_parse_dsl(join_array, k, translations) }
        else # Standard :has_many
          _br_hm_counts[k] = hm unless hm.options[:through] && !_br_associatives.fetch(hm.name, nil)
        end
      end
    end

    def self._brick_calculate_ordering(ordering, is_do_txt = true)
      quoted_table_name = table_name.split('.').map { |x| "\"#{x}\"" }.join('.')
      order_by_txt = [] if is_do_txt
      ordering = [ordering] if ordering && !ordering.is_a?(Array)
      order_by = ordering&.map do |ord_part| # %%% If a term is also used as an eqi-condition in the WHERE clause, it can be omitted from ORDER BY
                   case ord_part
                   when String
                     ord_expr = ord_part.gsub('^^^', quoted_table_name)
                     order_by_txt&.<<("Arel.sql(#{ord_expr})")
                     Arel.sql(ord_expr)
                   else # Expecting only Symbol
                     ord_part = "_br_#{ord_part}_ct" if _br_hm_counts.key?(ord_part)
                     # Retain any reference to a bt_descrip as being a symbol
                     # Was:  "#{quoted_table_name}.\"#{ord_part}\""
                     order_by_txt&.<<(_br_bt_descrip.key?(ord_part) ? ord_part : ord_part.inspect)
                     ord_part
                   end
                 end
      [order_by, order_by_txt]
    end

  private

    def self._brick_get_fks
      @_brick_get_fks ||= reflect_on_all_associations.select { |a2| a2.macro == :belongs_to }.each_with_object([]) do |bt, s|
        s << bt.foreign_key
        s << bt.foreign_type if bt.polymorphic?
      end
    end
  end

  class Relation
    attr_reader :_brick_chains

    # CLASS STUFF
    def _recurse_arel(piece, prefix = '')
      names = []
      # Our JOINs mashup of nested arrays and hashes
      # binding.pry if defined?(@arel)
      case piece
      when Array
        names += piece.inject([]) { |s, v| s + _recurse_arel(v, prefix) }
      when Hash
        names += piece.inject([]) do |s, v|
          new_prefix = "#{prefix}#{v.first}_"
          s << [v.last.shift, new_prefix]
          s + _recurse_arel(v.last, new_prefix)
        end

      # ActiveRecord AREL objects
      when Arel::Nodes::Join # INNER or OUTER JOIN
        # rubocop:disable Style/IdenticalConditionalBranches
        if piece.right.is_a?(Arel::Table) # Came in from AR < 3.2?
          # Arel 2.x and older is a little curious because these JOINs work "back to front".
          # The left side here is either another earlier JOIN, or at the end of the whole tree, it is
          # the first table.
          names += _recurse_arel(piece.left)
          # The right side here at the top is the very last table, and anywhere else down the tree it is
          # the later "JOIN" table of this pair.  (The table that comes after all the rest of the JOINs
          # from the left side.)
          names << [piece.right._arel_table_type, (piece.right.table_alias || piece.right.name)]
        else # "Normal" setup, fed from a JoinSource which has an array of JOINs
          # The left side is the "JOIN" table
          names += _recurse_arel(table = piece.left)
          # The expression on the right side is the "ON" clause
          # on = piece.right.expr
          # # Find the table which is not ourselves, and thus must be the "path" that led us here
          # parent = piece.left == on.left.relation ? on.right.relation : on.left.relation
          # binding.pry if piece.left.is_a?(Arel::Nodes::TableAlias)
          if table.is_a?(Arel::Nodes::TableAlias)
            alias_name = table.right
            table = table.left
          end
          (_brick_chains[table._arel_table_type] ||= []) << (alias_name || table.table_alias || table.name)
        end
        # rubocop:enable Style/IdenticalConditionalBranches
      when Arel::Table # Table
        names << [piece._arel_table_type, (piece.table_alias || piece.name)]
      when Arel::Nodes::TableAlias # Alias
        # Can get the real table name from:  self._recurse_arel(piece.left)
        names << [piece.left._arel_table_type, piece.right.to_s] # This is simply a string; the alias name itself
      when Arel::Nodes::JoinSource # Leaving this until the end because AR < 3.2 doesn't know at all about JoinSource!
        # Spin up an empty set of Brick alias name chains at the start
        @_brick_chains = {}
        # The left side is the "FROM" table
        names << (this_name = [piece.left._arel_table_type, (piece.left.table_alias || piece.left.name)])
        # # Do not currently need the root "FROM" table in our list of chains
        # (_brick_chains[this_name.first] ||= []) << this_name.last
        # The right side is an array of all JOINs
        piece.right.each { |join| names << _recurse_arel(join) }
      end
      names
    end

    # INSTANCE STUFF
    def _arel_alias_names
      # %%% If with Rails 3.1 and older you get "NoMethodError: undefined method `eq' for nil:NilClass"
      # when trying to call relation.arel, then somewhere along the line while navigating a has_many
      # relationship it can't find the proper foreign key.
      core = arel.ast.cores.first
      # Accommodate AR < 3.2
      if core.froms.is_a?(Arel::Table)
        # All recent versions of AR have #source which brings up an Arel::Nodes::JoinSource
        _recurse_arel(core.source)
      else
        # With AR < 3.2, "froms" brings up the top node, an Arel::Nodes::InnerJoin
        _recurse_arel(core.froms)
      end
    end

    def brick_select(params, selects = nil, order_by = nil, translations = {}, join_array = ::Brick::JoinArray.new)
      is_mysql = ActiveRecord::Base.connection.adapter_name == 'Mysql2'
      is_distinct = nil
      wheres = {}
      params.each do |k, v|
        next if ['_brick_schema', '_brick_order'].include?(k)

        case (ks = k.split('.')).length
        when 1
          next unless klass.column_names.any?(k) || klass._brick_get_fks.include?(k)
        when 2
          assoc_name = ks.first.to_sym
          # Make sure it's a good association name and that the model has that column name
          next unless klass.reflect_on_association(assoc_name)&.klass&.column_names&.any?(ks.last)

          join_array[assoc_name] = nil # Store this relation name in our special collection for .joins()
          is_distinct = true
          distinct!
        end
        wheres[k] = v.split(',')
      end

      # %%% Skip the metadata columns
      if selects&.empty? # Default to all columns
        tbl_no_schema = table.name.split('.').last
        columns.each do |col|
          col_alias = " AS _#{col.name}" if (col_name = col.name) == 'class'
          selects << if is_mysql
                       "`#{tbl_no_schema}`.`#{col_name}`#{col_alias}"
                     else
                       # Postgres can not use DISTINCT with any columns that are XML, so for any of those just convert to text
                       cast_as_text = '::text' if is_distinct && Brick.relations[klass.table_name]&.[](:cols)&.[](col.name)&.first&.start_with?('xml')
                       "\"#{tbl_no_schema}\".\"#{col_name}\"#{cast_as_text}#{col_alias}"
                     end
        end
      end

      if join_array.present?
        left_outer_joins!(join_array)
        # Without working from a duplicate, touching the AREL ast tree sets the @arel instance variable, which causes the relation to be immutable.
        (rel_dupe = dup)._arel_alias_names
        core_selects = selects.dup
        chains = rel_dupe._brick_chains
        id_for_tables = Hash.new { |h, k| h[k] = [] }
        field_tbl_names = Hash.new { |h, k| h[k] = {} }
        used_col_aliases = {} # Used to make sure there is not a name clash
        bt_columns = klass._br_bt_descrip.each_with_object([]) do |v, s|
          v.last.each do |k1, v1| # k1 is class, v1 is array of columns to snag
            next if chains[k1].nil?

            tbl_name = (field_tbl_names[v.first][k1] ||= shift_or_first(chains[k1])).split('.').last
            field_tbl_name = nil
            v1.map { |x| [translations[x[0..-2].map(&:to_s).join('.')], x.last] }.each_with_index do |sel_col, idx|
              field_tbl_name = (field_tbl_names[v.first][sel_col.first] ||= shift_or_first(chains[sel_col.first])).split('.').last

              # Postgres can not use DISTINCT with any columns that are XML, so for any of those just convert to text
              is_xml = is_distinct && Brick.relations[sel_col.first.table_name]&.[](:cols)&.[](sel_col.last)&.first&.start_with?('xml')
              # If it's not unique then also include the belongs_to association name before the column name
              if used_col_aliases.key?(col_alias = "_brfk_#{v.first}__#{sel_col.last}")
                col_alias = "_brfk_#{v.first}__#{v1[idx][-2..-1].map(&:to_s).join('__')}"
              end
              selects << if is_mysql
                           "`#{field_tbl_name}`.`#{sel_col.last}` AS `#{col_alias}`"
                         else
                           "\"#{field_tbl_name}\".\"#{sel_col.last}\"#{'::text' if is_xml} AS \"#{col_alias}\""
                         end
              used_col_aliases[col_alias] = nil
              v1[idx] << col_alias
            end

            unless id_for_tables.key?(v.first)
              # Accommodate composite primary key by allowing id_col to come in as an array
              ((id_col = k1.primary_key).is_a?(Array) ? id_col : [id_col]).each do |id_part|
                id_for_tables[v.first] << if id_part
                                            selects << if is_mysql
                                                         "#{"`#{tbl_name}`.`#{id_part}`"} AS `#{(id_alias = "_brfk_#{v.first}__#{id_part}")}`"
                                                       else
                                                         "#{"\"#{tbl_name}\".\"#{id_part}\""} AS \"#{(id_alias = "_brfk_#{v.first}__#{id_part}")}\""
                                                       end
                                            id_alias
                                          end
              end
              v1 << id_for_tables[v.first].compact
            end
          end
        end
        join_array.each do |assoc_name|
          # %%% Need to support {user: :profile}
          next unless assoc_name.is_a?(Symbol)

          table_alias = shift_or_first(chains[klass = reflect_on_association(assoc_name)&.klass])
          _assoc_names[assoc_name] = [table_alias, klass]
        end
      end
      # Add derived table JOIN for the has_many counts
      klass._br_hm_counts.each do |k, hm|
        associative = nil
        count_column = if hm.options[:through]
                         hm.foreign_key if (fk_col = (associative = klass._br_associatives&.[](hm.name))&.foreign_key)
                       else
                         fk_col = hm.foreign_key
                         poly_type = hm.inverse_of.foreign_type if hm.options.key?(:as)
                         pk = hm.klass.primary_key
                         (pk.is_a?(Array) ? pk.first : pk) || '*'
                       end
        next unless count_column # %%% Would be able to remove this when multiple foreign keys to same destination becomes bulletproof

        tbl_alias = is_mysql ? "`_br_#{hm.name}`" : "\"_br_#{hm.name}\""
        pri_tbl = hm.active_record
        pri_tbl_name = is_mysql ? "`#{pri_tbl.table_name}`" : "\"#{pri_tbl.table_name.gsub('.', '"."')}\""
        on_clause = []
        if fk_col.is_a?(Array) # Composite key?
          fk_col.each_with_index { |fk_col_part, idx| on_clause << "#{tbl_alias}.#{fk_col_part} = #{pri_tbl_name}.#{pri_tbl.primary_key[idx]}" }
          selects = fk_col.dup
        else
          selects = [fk_col]
          on_clause << "#{tbl_alias}.#{fk_col} = #{pri_tbl_name}.#{pri_tbl.primary_key}"
        end
        if poly_type
          selects << poly_type
          on_clause << "#{tbl_alias}.#{poly_type} = '#{name}'"
        end
        hm_table_name = is_mysql ? "`#{associative&.table_name || hm.klass.table_name}`" : "\"#{(associative&.table_name || hm.klass.table_name).gsub('.', '"."')}\""
        join_clause = "LEFT OUTER
JOIN (SELECT #{selects.join(', ')}, COUNT(#{'DISTINCT ' if hm.options[:through]}#{count_column
          }) AS _ct_ FROM #{hm_table_name} GROUP BY #{(1..selects.length).to_a.join(', ')}) AS #{tbl_alias}"
        joins!("#{join_clause} ON #{on_clause.join(' AND ')}")
      end
      where!(wheres) unless wheres.empty?
      # Must parse the order_by and see if there are any symbols which refer to BT associations
      # as they must be expanded to find the corresponding _br_model__column naming for each.
      if order_by.present?
        final_order_by = *order_by.each_with_object([]) do |v, s|
          if v.is_a?(Symbol)
            # Add the ordered series of columns derived from the BT based on its DSL
            if (bt_cols = klass._br_bt_descrip[v])
              bt_cols.values.each do |v1|
                v1.each { |v2| s << v2.last if v2.length > 1 }
              end
            else
              s << v
            end
          else # String stuff just comes straight through
            s << v
          end
        end
        order!(*final_order_by)
      end
      limit!(1000) # Don't want to get too carried away just yet
      wheres unless wheres.empty? # Return the specific parameters that we did use
    end

  private

    def shift_or_first(ary)
      ary.length > 1 ? ary.shift : ary.first
    end
  end

  module Inheritance
    module ClassMethods
    private

      alias _brick_find_sti_class find_sti_class
      def find_sti_class(type_name)
        if ::Brick.sti_models.key?(type_name)
          _brick_find_sti_class(type_name)
        else
          # This auto-STI is more of a brute-force approach, building modules where needed
          # The more graceful alternative is the overload of ActiveSupport::Dependencies#autoload_module! found below
          ::Brick.sti_models[type_name] = { base: self } unless type_name.blank?
          module_prefixes = type_name.split('::')
          module_prefixes.unshift('') unless module_prefixes.first.blank?
          module_name = module_prefixes[0..-2].join('::')
          if (snp = ::Brick.config.sti_namespace_prefixes)&.key?("::#{module_name}::") || snp&.key?("#{module_name}::") ||
             File.exist?(candidate_file = Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb'))
            _brick_find_sti_class(type_name) # Find this STI class normally
          else
            # Build missing prefix modules if they don't yet exist
            this_module = Object
            module_prefixes[1..-2].each do |module_name|
              this_module = if this_module.const_defined?(module_name)
                              this_module.const_get(module_name)
                            else
                              this_module.const_set(module_name.to_sym, Module.new)
                            end
            end
            begin
              if this_module.const_defined?(class_name = module_prefixes.last.to_sym)
                this_module.const_get(class_name)
              else
                # Build STI subclass and place it into the namespace module
                this_module.const_set(class_name, klass = Class.new(self))
                klass
              end
            rescue NameError => err
              if column_names.include?(inheritance_column)
                puts "Table #{table_name} has column #{inheritance_column} which ActiveRecord expects to use as its special inheritance column."
                puts "Unfortunately the value \"#{type_name}\" does not seem to refer to a valid type name, greatly confusing matters.  If that column is intended to be used for data and not STI, consider putting this line into your Brick initializer so that only for this table that column will not clash with ActiveRecord:"
                puts "  Brick.sti_type_column = { 'rails_#{inheritance_column}' => ['#{table_name}'] }"
                self
              else
                raise
              end
            end
          end
        end
      end
    end
  end
end

if ActiveSupport::Dependencies.respond_to?(:autoload_module!) # %%% Only works with previous non-zeitwerk auto-loading
  module ActiveSupport::Dependencies
    class << self
      # %%% Probably a little more targeted than other approaches we've taken thusfar
      # This happens before the whole parent check
      alias _brick_autoload_module! autoload_module!
      def autoload_module!(*args)
        into, const_name, qualified_name, path_suffix = args
        if (base_class_name = ::Brick.config.sti_namespace_prefixes&.fetch("::#{into.name}::", nil))
          base_class_name = "::#{base_class_name}" unless base_class_name.start_with?('::')
        end
        if (base_class = base_class_name&.constantize)
          ::Brick.sti_models[qualified_name] = { base: base_class }
          # Build subclass and place it into the specially STI-namespaced module
          into.const_set(const_name.to_sym, klass = Class.new(base_class))
          # %%% used to also have:  autoload_once_paths.include?(base_path) ||
          autoloaded_constants << qualified_name unless autoloaded_constants.include?(qualified_name)
          klass
        elsif (base_class = ::Brick.config.sti_namespace_prefixes&.fetch("::#{const_name}", nil)&.constantize)
          # Build subclass and place it into Object
          Object.const_set(const_name.to_sym, klass = Class.new(base_class))
        else
          _brick_autoload_module!(*args)
        end
      end
    end
  end
end

Module.class_exec do
  alias _brick_const_missing const_missing
  def const_missing(*args)
    if (self.const_defined?(args.first) && (possible = self.const_get(args.first)) && possible != self) ||
       (self != Object && Object.const_defined?(args.first) &&
         (
           (possible = Object.const_get(args.first)) &&
           (possible != self || (possible == self && possible.is_a?(Class)))
         )
       )
      return possible
    end
    class_name = args.first.to_s
    # self.name is nil when a model name is requested in an .erb file
    base_module = (self < ActiveRecord::Migration || !self.name) ? Object : self
    # See if a file is there in the same way that ActiveSupport::Dependencies#load_missing_constant
    # checks for it in ~/.rvm/gems/ruby-2.7.5/gems/activesupport-5.2.6.2/lib/active_support/dependencies.rb
    # that is, checking #qualified_name_for with:  from_mod, const_name
    # If we want to support namespacing in the future, might have to utilise something like this:
    # path_suffix = ActiveSupport::Dependencies.qualified_name_for(Object, args.first).underscore
    # return self._brick_const_missing(*args) if ActiveSupport::Dependencies.search_for_file(path_suffix)
    # If the file really exists, go and snag it:
    if ActiveSupport::Dependencies.search_for_file(class_name.underscore)
      return base_module._brick_const_missing(*args)
      # elsif ActiveSupport::Dependencies.search_for_file(filepath) # Last-ditch effort to pick this thing up before we fill in the gaps on our own
      #   my_const = parent.const_missing(class_name) # ends up having:  MyModule::MyClass
      #   return my_const
    else
      filepath = base_module.name&.split('::')&.[](0..-2) unless base_module == Object
      filepath = ((filepath || []) + [class_name]).join('/').underscore + '.rb'
      if ActiveSupport::Dependencies.search_for_file(filepath) # Last-ditch effort to pick this thing up before we fill in the gaps on our own
        return base_module._brick_const_missing(*args)
      end
    end

    relations = ::Brick.relations
    # puts "ON OBJECT: #{args.inspect}" if self.module_parent == Object
    result = if ::Brick.enable_controllers? && class_name.end_with?('Controller') && (plural_class_name = class_name[0..-11]).length.positive?
               # Otherwise now it's up to us to fill in the gaps
               # (Go over to underscores for a moment so that if we have something come in like VABCsController then the model name ends up as
               # Vabc instead of VABC)
               full_class_name = +''
               full_class_name << "::#{self.name}" unless self == Object
               full_class_name << "::#{plural_class_name.underscore.singularize.camelize}"
               if plural_class_name == 'BrickSwagger' ||
                  (
                    (::Brick.config.add_status || ::Brick.config.add_orphans) &&
                    plural_class_name == 'BrickGem'
                  ) ||
                  model = self.const_get(full_class_name)
                 # if it's a controller and no match or a model doesn't really use the same table name, eager load all models and try to find a model class of the right name.
                 Object.send(:build_controller, self, class_name, plural_class_name, model, relations)
               end
             elsif (::Brick.enable_models? || ::Brick.enable_controllers?) && # Schema match?
                   base_module == Object && # %%% This works for Person::Person -- but also limits us to not being able to allow more than one level of namespacing
                   (schema_name = [(singular_table_name = class_name.underscore),
                                   (table_name = singular_table_name.pluralize),
                                   class_name,
                                   (plural_class_name = class_name.pluralize)].find { |s| Brick.db_schemas.include?(s) }&.camelize ||
                                  (::Brick.config.sti_namespace_prefixes&.key?("::#{class_name}::") && class_name))
               # Build out a module for the schema if it's namespaced
               # schema_name = schema_name.camelize
               base_module.const_set(schema_name.to_sym, (built_module = Module.new))

               [built_module, "module #{schema_name}; end\n"]
               #  # %%% Perhaps an option to use the first module just as schema, and additional modules as namespace with a table name prefix applied
             elsif ::Brick.enable_models?
               # Custom inheritable Brick base model?
               class_name = (inheritable_name = class_name)[5..-1] if class_name.start_with?('Brick')
               Object.send(:build_model, relations, base_module, name, class_name, inheritable_name)
             end
    if result
      built_class, code = result
      puts "\n#{code}\n"
      built_class
    elsif ::Brick.config.sti_namespace_prefixes&.key?("::#{class_name}") && !schema_name
#         module_prefixes = type_name.split('::')
#         path = base_module.name.split('::')[0..-2] + []
#         module_prefixes.unshift('') unless module_prefixes.first.blank?
#         candidate_file = Rails.root.join('app/models' + module_prefixes.map(&:underscore).join('/') + '.rb')
      base_module._brick_const_missing(*args)
    # elsif base_module != Object
    #   module_parent.const_missing(*args)
    else
      puts "MISSING! #{base_module.name} #{args.inspect} #{table_name}"
      base_module._brick_const_missing(*args)
    end
  end
end

class Object
  class << self

  private

    def build_model(relations, base_module, base_name, class_name, inheritable_name = nil)
      if (base_model = ::Brick.config.sti_namespace_prefixes&.fetch("::#{base_module.name}::", nil)&.constantize) || # Are we part of an auto-STI namespace? ...
         base_module != Object # ... or otherwise already in some namespace?
        schema_name = [(singular_schema_name = base_name.underscore),
                       (schema_name = singular_schema_name.pluralize),
                       base_name,
                       base_name.pluralize].find { |s| Brick.db_schemas.include?(s) }
      end
      plural_class_name = ActiveSupport::Inflector.pluralize(model_name = class_name)
      # If it's namespaced then we turn the first part into what would be a schema name
      singular_table_name = ActiveSupport::Inflector.underscore(model_name).gsub('/', '.')

      if base_model
        schema_name = base_name.underscore # For the auto-STI namespace models
        table_name = base_model.table_name
        build_model_worker(base_module, inheritable_name, model_name, singular_table_name, table_name, relations, table_name)
      else
        # Adjust for STI if we know of a base model for the requested model name
        # %%% Does not yet work with namespaced model names.  Perhaps prefix with plural_class_name when doing the lookups here.
        table_name = if (base_model = ::Brick.sti_models[model_name]&.fetch(:base, nil) || ::Brick.existing_stis[model_name]&.constantize)
                       base_model.table_name
                     else
                       ActiveSupport::Inflector.pluralize(singular_table_name)
                     end
        if ::Brick.apartment_multitenant &&
           Apartment.excluded_models.include?(table_name.singularize.camelize)
          schema_name = Apartment.default_schema
        end
        # Maybe, just maybe there's a database table that will satisfy this need
        if (matching = [table_name, singular_table_name, plural_class_name, model_name].find { |m| relations.key?(schema_name ? "#{schema_name}.#{m}" : m) })
          build_model_worker(schema_name, inheritable_name, model_name, singular_table_name, table_name, relations, matching)
        end
      end
    end

    def build_model_worker(schema_name, inheritable_name, model_name, singular_table_name, table_name, relations, matching)
      if ::Brick.apartment_multitenant &&
         schema_name == Apartment.default_schema
        relation = relations["#{schema_name}.#{matching}"]
      end
      full_name = if relation || schema_name.blank?
                    inheritable_name || model_name
                  else # Prefix the schema to the table name + prefix the schema namespace to the class name
                    schema_module = if schema_name.instance_of?(Module) # from an auto-STI namespace?
                                      schema_name
                                    else
                                      matching = "#{schema_name}.#{matching}"
                                      (Brick.db_schemas[schema_name] ||= self.const_get(schema_name.camelize))
                                    end
                    "#{schema_module&.name}::#{inheritable_name || model_name}"
                  end

      return if ((is_view = (relation ||= relations[matching]).key?(:isView)) && ::Brick.config.skip_database_views) ||
                ::Brick.config.exclude_tables.include?(matching)

      # Are they trying to use a pluralised class name such as "Employees" instead of "Employee"?
      if table_name == singular_table_name && !ActiveSupport::Inflector.inflections.uncountable.include?(table_name)
        unless ::Brick.config.sti_namespace_prefixes&.key?("::#{singular_table_name.camelize}::")
          puts "Warning: Class name for a model that references table \"#{matching
               }\" should be \"#{ActiveSupport::Inflector.singularize(inheritable_name || model_name)}\"."
        end
        return
      end

      full_model_name = full_name.split('::').tap { |fn| fn[-1] = model_name }.join('::')
      if (base_model = ::Brick.sti_models[full_model_name]&.fetch(:base, nil) || ::Brick.existing_stis[full_model_name]&.constantize)
        is_sti = true
      else
        base_model = ::Brick.config.models_inherit_from || ActiveRecord::Base
      end
      hmts = nil
      code = +"class #{full_name} < #{base_model.name}\n"
      built_model = Class.new(base_model) do |new_model_class|
        (schema_module || Object).const_set((inheritable_name || model_name).to_sym, new_model_class)
        if inheritable_name
          new_model_class.define_singleton_method :inherited do |subclass|
            super(subclass)
            if subclass.name == model_name
              puts "#{full_model_name} properly extends from #{full_name}"
            else
              puts "should be \"class #{model_name} < #{inheritable_name}\"\n           (not \"#{subclass.name} < #{inheritable_name}\")"
            end
          end
          self.abstract_class = true
          code << "  self.abstract_class = true\n"
        end
        # Accommodate singular or camel-cased table names such as "order_detail" or "OrderDetails"
        code << "  self.table_name = '#{self.table_name = matching}'\n" if inheritable_name || table_name != matching

        # Override models backed by a view so they return true for #is_view?
        # (Dynamically-created controllers and view templates for such models will then act in a read-only way)
        if is_view
          new_model_class.define_singleton_method :'is_view?' do
            true
          end
          code << "  def self.is_view?; true; end\n"
        end

        db_pks = relation[:cols]&.map(&:first)
        has_pk = _brick_primary_key(relation).length.positive? && (db_pks & _brick_primary_key).sort == _brick_primary_key.sort
        our_pks = relation[:pkey].values.first
        # No primary key, but is there anything UNIQUE?
        # (Sort so that if there are multiple UNIQUE constraints we'll pick one that uses the least number of columns.)
        our_pks = relation[:ukeys].values.sort { |a, b| a.length <=> b.length }.first unless our_pks&.present?
        if has_pk
          code << "  # Primary key: #{_brick_primary_key.join(', ')}\n" unless _brick_primary_key == ['id']
        elsif our_pks&.present?
          if our_pks.length > 1 && respond_to?(:'primary_keys=') # Using the composite_primary_keys gem?
            new_model_class.primary_keys = our_pks
            code << "  self.primary_keys = #{our_pks.map(&:to_sym).inspect}\n"
          else
            new_model_class.primary_key = (pk_sym = our_pks.first.to_sym)
            code << "  self.primary_key = #{pk_sym.inspect}\n"
          end
          _brick_primary_key(relation) # Set the newly-found PK in the instance variable
        elsif (possible_pk = ActiveRecord::Base.get_primary_key(base_class.name)) && relation[:cols][possible_pk]
          new_model_class.primary_key = (possible_pk = possible_pk.to_sym)
          code << "  self.primary_key = #{possible_pk.inspect}\n"
        else
          code << "  # Could not identify any column(s) to use as a primary key\n" unless is_view
        end
        if (sti_col = relation.fetch(:sti_col, nil))
          new_model_class.send(:'inheritance_column=', sti_col)
          code << "  self.inheritance_column = #{sti_col.inspect}\n"
        end

        unless is_sti
          fks = relation[:fks] || {}
          # Do the bulk of the has_many / belongs_to processing, and store details about HMT so they can be done at the very last
          hmts = fks.each_with_object(Hash.new { |h, k| h[k] = [] }) do |fk, hmts|
            # The key in each hash entry (fk.first) is the constraint name
            inverse_assoc_name = (assoc = fk.last)[:inverse]&.fetch(:assoc_name, nil)
            if (invs = assoc[:inverse_table]).is_a?(Array)
              if assoc[:is_bt]
                invs = invs.first # Just do the first one of what would be multiple identical polymorphic belongs_to
              else
                invs.each { |inv| build_bt_or_hm(full_name, relations, relation, hmts, assoc, inverse_assoc_name, inv, code) }
              end
            end
            build_bt_or_hm(full_name, relations, relation, hmts, assoc, inverse_assoc_name, invs, code) unless invs.is_a?(Array)
            hmts
          end
          # # Not NULLables
          # # %%% For the minute we've had to pull this out because it's been troublesome implementing the NotNull validator
          # relation[:cols].each do |col, datatype|
          #   if (datatype[3] && _brick_primary_key.exclude?(col) && ::Brick.config.metadata_columns.exclude?(col)) ||
          #      ::Brick.config.not_nullables.include?("#{matching}.#{col}")
          #     code << "  validates :#{col}, not_null: true\n"
          #     self.send(:validates, col.to_sym, { not_null: true })
          #   end
          # end
        end
      end # class definition
      # Having this separate -- will this now work out better?
        built_model.class_exec do
          hmts&.each do |hmt_fk, hms|
            hmt_fk = hmt_fk.tr('.', '_')
            hms.each do |hm|
              # %%% Need to confirm that HMTs work when they are built from has_manys with custom names
              through = ::Brick.config.schema_behavior[:multitenant] ? hm.first[:assoc_name] : hm.first[:inverse_table].tr('.', '_').pluralize
              options = {}
              hmt_name = if hms.length > 1
                           if hms[0].first[:inverse][:assoc_name] == hms[1].first[:inverse][:assoc_name] # Same BT names pointing back to us? (Most common scenario)
                             "#{hmt_fk}_through_#{hm.first[:assoc_name]}"
                           else # Use BT names to provide uniqueness
                             if self.name.underscore.singularize == hm.first[:alternate_name]
                               #  Has previously been:
                               # # If it folds back on itself then look at the other side
                               # # (At this point just infer the source be the inverse of the first has_many that
                               # # we find that is not ourselves.  If there are more than two then uh oh, can't
                               # # yet handle that rare circumstance!)
                               # other = hms.find { |hm1| hm1 != hm } # .first[:fk]
                               # options[:source] = other.first[:inverse][:assoc_name].to_sym
                               #  And also has been:
                               # hm.first[:inverse][:assoc_name].to_sym
                               options[:source] = hm.last.to_sym
                             else
                               through = hm.first[:alternate_name].pluralize
                             end
                             singular_assoc_name = hm.first[:inverse][:assoc_name].singularize
                             "#{singular_assoc_name}_#{hmt_fk}"
                           end
                         else
                           hmt_fk
                         end
              options[:through] = through.to_sym
              if relation[:fks].any? { |k, v| v[:assoc_name] == hmt_name }
                hmt_name = "#{hmt_name.singularize}_#{hm.first[:assoc_name]}"
                # Was:
                # options[:class_name] = hm.first[:inverse_table].singularize.camelize
                # options[:foreign_key] = hm.first[:fk].to_sym
                far_assoc = relations[hm.first[:inverse_table]][:fks].find { |_k, v| v[:assoc_name] == hm.last }
                options[:class_name] = far_assoc.last[:inverse_table].singularize.camelize
                options[:foreign_key] = far_assoc.last[:fk].to_sym
              end
              options[:source] ||= hm.last.to_sym unless hmt_name.singularize == hm.last
              code << "  has_many :#{hmt_name}#{options.map { |opt| ", #{opt.first}: #{opt.last.inspect}" }.join}\n"
              self.send(:has_many, hmt_name.to_sym, **options)
            end
          end
        end
        code << "end # model #{full_name}\n"
      [built_model, code]
    end

    def build_bt_or_hm(full_name, relations, relation, hmts, assoc, inverse_assoc_name, inverse_table, code)
      singular_table_name = inverse_table&.singularize
      options = {}
      macro = if assoc[:is_bt]
                # Try to take care of screwy names if this is a belongs_to going to an STI subclass
                assoc_name = if (primary_class = assoc.fetch(:primary_class, nil)) &&
                               sti_inverse_assoc = primary_class.reflect_on_all_associations.find do |a|
                                 a.macro == :has_many && a.options[:class_name] == self.name && assoc[:fk] == a.foreign_key
                               end
                               sti_inverse_assoc.options[:inverse_of]&.to_s || assoc_name
                             else
                               assoc[:assoc_name]
                             end
                options[:optional] = true if assoc.key?(:optional)
                if assoc.key?(:polymorphic)
                  options[:polymorphic] = true
                else
                  need_class_name = singular_table_name.underscore != assoc_name
                  need_fk = "#{assoc_name}_id" != assoc[:fk]
                end
                if (inverse = assoc[:inverse])
                  # If it's multitenant with something like:  public.____ ...
                  if (it_parts = inverse_table.split('.')).length > 1 &&
                     ::Brick.apartment_multitenant &&
                     it_parts.first == Apartment.default_schema
                    it_parts.shift # ... then ditch the generic schema name
                  end
                  inverse_assoc_name, _x = _brick_get_hm_assoc_name(relations[inverse_table], inverse, it_parts.join('_').singularize)
                  has_ones = ::Brick.config.has_ones&.fetch(it_parts.join('/').singularize.camelize, nil)
                  if has_ones&.key?(singular_inv_assoc_name = ActiveSupport::Inflector.singularize(inverse_assoc_name.tr('.', '_')))
                    inverse_assoc_name = if has_ones[singular_inv_assoc_name]
                                           need_inverse_of = true
                                           has_ones[singular_inv_assoc_name]
                                         else
                                           singular_inv_assoc_name
                                         end
                  end
                end
                :belongs_to
              else
                # Are there multiple foreign keys out to the same table?
                assoc_name, need_class_name = _brick_get_hm_assoc_name(relation, assoc)
                if assoc.key?(:polymorphic)
                  options[:as] = assoc[:fk].to_sym
                else
                  need_fk = "#{ActiveSupport::Inflector.singularize(assoc[:inverse][:inverse_table].split('.').last)}_id" != assoc[:fk]
                end
                has_ones = ::Brick.config.has_ones&.fetch(full_name, nil)
                if has_ones&.key?(singular_assoc_name = ActiveSupport::Inflector.singularize(assoc_name.tr('.', '_')))
                  assoc_name = if (custom_assoc_name = has_ones[singular_assoc_name])
                                 need_class_name = custom_assoc_name != singular_assoc_name
                                 custom_assoc_name
                               else
                                 singular_assoc_name
                               end
                  :has_one
                else
                  :has_many
                end
              end
      # Figure out if we need to specially call out the class_name and/or foreign key
      # (and if either of those then definitely also a specific inverse_of)
      if (singular_table_parts = singular_table_name.split('.')).length > 1 &&
         ::Brick.config.schema_behavior[:multitenant] && singular_table_parts.first == 'public'
        singular_table_parts.shift
      end
      options[:class_name] = "::#{assoc[:primary_class]&.name || singular_table_parts.map(&:camelize).join('::')}" if need_class_name
      # Work around a bug in CPK where self-referencing belongs_to associations double up their foreign keys
      if need_fk # Funky foreign key?
        options[:foreign_key] = if assoc[:fk].is_a?(Array)
                                  assoc_fk = assoc[:fk].uniq
                                  assoc_fk.length < 2 ? assoc_fk.first : assoc_fk
                                else
                                  assoc[:fk].to_sym
                                end
      end
      options[:inverse_of] = inverse_assoc_name.tr('.', '_').to_sym if inverse_assoc_name && (need_class_name || need_fk || need_inverse_of)

      # Prepare a list of entries for "has_many :through"
      if macro == :has_many
        relations[inverse_table][:hmt_fks].each do |k, hmt_fk|
          next if k == assoc[:fk]

          hmts[ActiveSupport::Inflector.pluralize(hmt_fk.last)] << [assoc, hmt_fk.first]
        end
      end
      # And finally create a has_one, has_many, or belongs_to for this association
      assoc_name = assoc_name.tr('.', '_').to_sym
      code << "  #{macro} #{assoc_name.inspect}#{options.map { |k, v| ", #{k}: #{v.inspect}" }.join}\n"
      self.send(macro, assoc_name, **options)
    end

    def default_ordering(table_name, pk)
      case (order_tbl = ::Brick.config.order[table_name]) && (order_default = order_tbl[:_brick_default])
      when Array
        order_default.map { |od_part| order_tbl[od_part] || od_part }
      when Symbol
        order_tbl[order_default] || order_default
      else
        pk.map(&:to_sym) # If it's not a custom ORDER BY, just use the key
      end
    end

    def build_controller(namespace, class_name, plural_class_name, model, relations)
      table_name = ActiveSupport::Inflector.underscore(plural_class_name)
      singular_table_name = ActiveSupport::Inflector.singularize(table_name)
      pk = model&._brick_primary_key(relations.fetch(table_name, nil))
      is_mysql = ActiveRecord::Base.connection.adapter_name == 'Mysql2'

      namespace_name = "#{namespace.name}::" if namespace
      code = +"class #{namespace_name}#{class_name} < ApplicationController\n"
      built_controller = Class.new(ActionController::Base) do |new_controller_class|
        (namespace || Object).const_set(class_name.to_sym, new_controller_class)

        # Brick-specific pages
        case plural_class_name
        when 'BrickGem'
          self.define_method :status do
            instance_variable_set(:@resources, ::Brick.get_status_of_resources)
          end
          self.define_method :orphans do
            instance_variable_set(:@orphans, ::Brick.find_orphans(::Brick.set_db_schema(params)))
          end
          return [new_controller_class, code + ' # BrickGem controller']
        when 'BrickSwagger'
          is_swagger = true # if request.format == :json)
        end

        self.protect_from_forgery unless: -> { self.request.format.js? }
        self.define_method :index do
          # We do all of this now so that bt_descrip and hm_counts are available on the model early in case the user
          # wants to do an ORDER BY based on any of that
          translations = {}
          join_array = ::Brick::JoinArray.new
          is_add_bts = is_add_hms = true
          # This builds out bt_descrip and hm_counts on the model
          model._brick_calculate_bts_hms(translations, join_array) if is_add_bts || is_add_hms

          if is_swagger
            json = { 'openapi': '3.0.1', 'info': { 'title': 'API V1', 'version': 'v1' },
                     'servers': [
                       { 'url': 'https://{defaultHost}', 'variables': { 'defaultHost': { 'default': 'www.example.com' } } }
                     ]
                   }
            json['paths'] = relations.inject({}) do |s, v|
              s["/api/v1/#{v.first}"] = {
                'get': {
                  'summary': "list #{v.first}",
                  'parameters': v.last[:cols].map { |k, v| { 'name' => k, 'schema': { 'type': v.first } } },
                  'responses': { '200': { 'description': 'successful' } }
                }
              }
              # next if v.last[:isView]

              s["/api/v1/#{v.first}/{id}"] = {
                'patch': {
                  'summary': "update a #{v.first.singularize}",
                  'parameters': v.last[:cols].reject { |k, v| Brick.config.metadata_columns.include?(k) }.map do |k, v|
                    { 'name' => k, 'schema': { 'type': v.first } }
                  end,
                  'responses': { '200': { 'description': 'successful' } }
                }
                # "/api/v1/books/{id}": {
                #   "parameters": [
                #     {
                #       "name": "id",
                #       "in": "path",
                #       "description": "id",
                #       "required": true,
                #       "schema": {
                #         "type": "string"
                #       }
                #     },
                #     {
                #       "name": "Authorization",
                #       "in": "header",
                #       "schema": {
                #         "type": "string"
                #       }
                #     }
                #   ],
              }
              s
            end
            render inline: json.to_json, content_type: request.format
            return
          end

          # Normal (non-swagger) request

          # %%% Allow params to define which columns to use for order_by
          # Overriding the default by providing a querystring param?
          ordering = params['_brick_order']&.split(',')&.map(&:to_sym) || Object.send(:default_ordering, table_name, pk)
          order_by, _ = model._brick_calculate_ordering(ordering, true) # Don't do the txt part

          ::Brick.set_db_schema(params)
          if request.format == :csv # Asking for a template?
            require 'csv'
            exported_csv = CSV.generate(force_quotes: false) do |csv_out|
              model.df_export(model.brick_import_template).each { |row| csv_out << row }
            end
            render inline: exported_csv, content_type: request.format
            return
          elsif request.format == :js # Asking for JSON?
            render inline: model.df_export(model.brick_import_template).to_json, content_type: request.format
            return
          end

          @_brick_params = (ar_relation = model.all).brick_select(params, (selects = []), order_by, translations, join_array)
          # %%% Add custom HM count columns
          # %%% What happens when the PK is composite?
          counts = model._br_hm_counts.each_with_object([]) do |v, s|
            s << (is_mysql ? "`_br_#{v.first}`._ct_ AS \"_br_#{v.first}_ct\"" : "\"_br_#{v.first}\"._ct_ AS \"_br_#{v.first}_ct\"")
          end
          instance_variable_set("@#{table_name}".to_sym, ar_relation.dup._select!(*selects, *counts))
          if namespace && (idx = lookup_context.prefixes.index(table_name))
            lookup_context.prefixes[idx] = "#{namespace.name.underscore}/#{lookup_context.prefixes[idx]}"
          end
          @_brick_excl = session[:_brick_exclude]&.split(',')&.each_with_object([]) do |excl, s|
                           if (excl_parts = excl.split('.')).first == table_name
                             s << excl_parts.last
                           end
                         end
          @_brick_bt_descrip = model._br_bt_descrip
          @_brick_hm_counts = model._br_hm_counts
          @_brick_join_array = join_array
          @_brick_erd = params['_brick_erd']&.to_i
        end

        _, order_by_txt = model._brick_calculate_ordering(default_ordering(table_name, pk))
        code << "  def index\n"
        code << "    @#{table_name} = #{model.name}#{pk&.present? ? ".order(#{order_by_txt.join(', ')})" : '.all'}\n"
        code << "    @#{table_name}.brick_select(params)\n"
        code << "  end\n"

        is_pk_string = nil
        if (pk_col = model&.primary_key)
          code << "  def show\n"
          code << "    #{find_by_name = "find_#{singular_table_name}"}\n"
          code << "  end\n"
          self.define_method :show do
            ::Brick.set_db_schema(params)
            id = if model.columns_hash[pk_col]&.type == :string
                   is_pk_string = true
                   params[:id]
                 else
                   params[:id]&.split(/[\/,_]/)
                 end
            id = id.first if id.is_a?(Array) && id.length == 1
            instance_variable_set("@#{singular_table_name}".to_sym, find_obj)
          end
        end

        # By default, views get marked as read-only
        # unless model.readonly # (relation = relations[model.table_name]).key?(:isView)
          code << "  def new\n"
          code << "    @#{singular_table_name} = #{model.name}.new\n"
          code << "  end\n"
          self.define_method :new do
            ::Brick.set_db_schema(params)
            instance_variable_set("@#{singular_table_name}".to_sym, model.new)
          end

          params_name_sym = (params_name = "#{singular_table_name}_params").to_sym

          code << "  def create\n"
          code << "    @#{singular_table_name} = #{model.name}.create(#{params_name})\n"
          code << "  end\n"
          self.define_method :create do
            ::Brick.set_db_schema(params)
            if (is_json = request.content_type == 'application/json') && (col = params['_brick_exclude'])
              session[:_brick_exclude] = ((session[:_brick_exclude]&.split(',') || []) + ["#{table_name}.#{col}"]).join(',')
              render json: { result: ::Brick.exclude_column(table_name, col) }
            elsif is_json && (col = params['_brick_unexclude'])
              if (excls = ((session[:_brick_exclude]&.split(',') || []) - ["#{table_name}.#{col}"]).join(',')).empty?
                session.delete(:_brick_exclude)
              else
                session[:_brick_exclude] = excls
              end
              render json: { result: ::Brick.unexclude_column(table_name, col) }
            else
              instance_variable_set("@#{singular_table_name}".to_sym,
                                    model.send(:create, send(params_name_sym)))
            end
          end

          if pk_col
            # if (schema = ::Brick.config.schema_behavior[:multitenant]&.fetch(:schema_to_analyse, nil)) && ::Brick.db_schemas&.include?(schema)
            #   ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?;", schema)
            # end

            is_need_params = true
            code << "  def edit\n"
            code << "    #{find_by_name}\n"
            code << "  end\n"
            self.define_method :edit do
              ::Brick.set_db_schema(params)
              instance_variable_set("@#{singular_table_name}".to_sym, find_obj)
            end

            code << "  def update\n"
            code << "    #{find_by_name}.update(#{params_name})\n"
            code << "  end\n"
            self.define_method :update do
              ::Brick.set_db_schema(params)
              if request.format == :csv # Importing CSV?
                require 'csv'
                # See if internally it's likely a TSV file (tab-separated)
                tab_counts = []
                5.times { tab_counts << request.body.readline.count("\t") unless request.body.eof? }
                request.body.rewind
                separator = "\t" if tab_counts.length > 0 && tab_counts.uniq.length == 1 && tab_counts.first > 0
                result = model.df_import(CSV.parse(request.body, { col_sep: separator || :auto }), model.brick_import_template)
                # render inline: exported_csv, content_type: request.format
                return
              # elsif request.format == :js # Asking for JSON?
              #   render inline: model.df_export(true).to_json, content_type: request.format
              #   return
              end

              instance_variable_set("@#{singular_table_name}".to_sym, (obj = find_obj))
              obj.send(:update, send(params_name_sym))
            end

            code << "  def destroy\n"
            code << "    #{find_by_name}.destroy\n"
            code << "  end\n"
            self.define_method :destroy do
              ::Brick.set_db_schema(params)
              instance_variable_set("@#{singular_table_name}".to_sym, find_obj.send(:destroy))
            end
          end

          code << "private\n" if pk_col || is_need_params

          if pk_col
            code << "  def find_#{singular_table_name}
    id = params[:id]&.split(/[\\/,_]/)
    @#{singular_table_name} = #{model.name}.find(id.is_a?(Array) && id.length == 1 ? id.first : id)
  end\n"
            self.define_method :find_obj do
              id = is_pk_string ? params[:id] : params[:id]&.split(/[\/,_]/)
              model.find(id.is_a?(Array) && id.length == 1 ? id.first : id)
            end
          end

          if is_need_params
            code << "  def #{params_name}\n"
            permits = model.columns_hash.keys.map(&:to_sym)
            permits_txt = permits.map(&:inspect) +
                          model.reflect_on_all_associations.select { |assoc| assoc.macro == :has_many && assoc.options[:through] }.map do |assoc|
                            permits << { "#{assoc.name.to_s.singularize}_ids".to_sym => [] }
                            "#{assoc.name.to_s.singularize}_ids: []"
                          end
            code << "    params.require(:#{require_name = model.name.underscore.tr('/', '_')
                             }).permit(#{permits_txt.join(', ')})\n"
            code << "  end\n"
            self.define_method(params_name) do
              params.require(require_name.to_sym).permit(permits)
            end
            private params_name
            # Get column names for params from relations[model.table_name][:cols].keys
          end
        # end
        code << "end # #{namespace_name}#{class_name}\n"
      end # class definition
      [built_controller, code]
    end

    def _brick_get_hm_assoc_name(relation, hm_assoc, source = nil)
      if (relation[:hm_counts][hm_assoc[:assoc_name]]&.> 1) &&
         hm_assoc[:alternate_name] != (source || name.underscore)
        plural = ActiveSupport::Inflector.pluralize(hm_assoc[:alternate_name])
        new_alt_name = (hm_assoc[:alternate_name] == name.underscore) ? "#{hm_assoc[:assoc_name].singularize}_#{plural}" : plural
        # uniq = 1
        # while same_name = relation[:fks].find { |x| x.last[:assoc_name] == hm_assoc[:assoc_name] && x.last != hm_assoc }
        #   hm_assoc[:assoc_name] = "#{hm_assoc_name}_#{uniq += 1}"
        # end
        # puts new_alt_name
        # hm_assoc[:assoc_name] = new_alt_name
        [new_alt_name, true]
      else
        assoc_name = hm_assoc[:inverse_table].pluralize
        # hm_assoc[:assoc_name] = assoc_name
        [assoc_name, assoc_name.include?('.')]
      end
    end
  end
end

# ==========================================================
# Get info on all relations during first database connection
# ==========================================================

module ActiveRecord::ConnectionHandling
  alias _brick_establish_connection establish_connection
  def establish_connection(*args)
    conn = _brick_establish_connection(*args)
    begin
      _brick_reflect_tables
    rescue ActiveRecord::NoDatabaseError
    end
    conn
  end

  # This is done separately so that during testing it can be called right after a migration
  # in order to make sure everything is good.
  def _brick_reflect_tables
    initializer_loaded = false
    if (relations = ::Brick.relations).empty?
      # If there's schema things configured then we only expect our initializer to be named exactly this
      if File.exist?(brick_initializer = Rails.root.join('config/initializers/brick.rb'))
        initializer_loaded = load brick_initializer
      end
      # Load the initializer for the Apartment gem a little early so that if .excluded_models and
      # .default_schema are specified then we can work with non-tenanted models more appropriately
      apartment = Object.const_defined?('Apartment')
      if apartment && File.exist?(apartment_initializer = Rails.root.join('config/initializers/apartment.rb'))
        load apartment_initializer
        apartment_excluded = Apartment.excluded_models
      end
      # Only for Postgres  (Doesn't work in sqlite3 or MySQL)
      # puts ActiveRecord::Base.execute_sql("SELECT current_setting('SEARCH_PATH')").to_a.inspect

      is_postgres = nil
      case ActiveRecord::Base.connection.adapter_name
      when 'PostgreSQL'
        is_postgres = true
        db_schemas = ActiveRecord::Base.execute_sql('SELECT DISTINCT table_schema FROM INFORMATION_SCHEMA.tables;')
        ::Brick.db_schemas = db_schemas.each_with_object({}) do |row, s|
          row = row.is_a?(String) ? row : row['table_schema']
          # Remove any system schemas
          s[row] = nil unless ['information_schema', 'pg_catalog'].include?(row)
        end
        if (is_multitenant = (multitenancy = ::Brick.config.schema_behavior[:multitenant]) &&
           (sta = multitenancy[:schema_to_analyse]) != 'public') &&
           ::Brick.db_schemas.include?(sta)
          ::Brick.default_schema = schema = sta
          ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", schema)
        end
      when 'Mysql2'
        ::Brick.default_schema = schema = ActiveRecord::Base.connection.current_database
      when 'SQLite'
        # %%% Retrieve internal ActiveRecord table names like this:
        # ActiveRecord::Base.internal_metadata_table_name, ActiveRecord::Base.schema_migrations_table_name
        sql = "SELECT m.name AS relation_name, UPPER(m.type) AS table_type,
          p.name AS column_name, p.type AS data_type,
          CASE p.pk WHEN 1 THEN 'PRIMARY KEY' END AS const
        FROM sqlite_master AS m
          INNER JOIN pragma_table_info(m.name) AS p
        WHERE m.name NOT IN (?, ?)
        ORDER BY m.name, p.cid"
      else
        puts "Unfamiliar with connection adapter #{ActiveRecord::Base.connection.adapter_name}"
      end

      ::Brick.db_schemas ||= {}

      if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        if (possible_schema = ::Brick.config.schema_behavior&.[](:multitenant)&.[](:schema_to_analyse))
          if ::Brick.db_schemas.key?(possible_schema)
            ::Brick.default_schema = schema = possible_schema
            ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", schema)
          else
            puts "*** In the brick.rb initializer the line \"::Brick.schema_behavior = ...\" refers to a schema called \"#{possible_schema}\".  This schema does not exist. ***"
          end
        end
      end

      # %%% Retrieve internal ActiveRecord table names like this:
      # ActiveRecord::Base.internal_metadata_table_name, ActiveRecord::Base.schema_migrations_table_name
      # For if it's not SQLite -- so this is the Postgres and MySQL version
      measures = []
      case ActiveRecord::Base.connection.adapter_name
      when 'PostgreSQL', 'SQLite' # These bring back a hash for each row because the query uses column aliases
        # schema ||= 'public' if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        ActiveRecord::Base.retrieve_schema_and_tables(sql, is_postgres, schema).each do |r|
          # If Apartment gem lists the table as being associated with a non-tenanted model then use whatever it thinks
          # is the default schema, usually 'public'.
          schema_name = if ::Brick.config.schema_behavior[:multitenant]
                          Apartment.default_schema if apartment_excluded&.include?(r['relation_name'].singularize.camelize)
                        elsif ![schema, 'public'].include?(r['schema'])
                          r['schema']
                        end
          relation_name = schema_name ? "#{schema_name}.#{r['relation_name']}" : r['relation_name']
          relation = relations[relation_name]
          relation[:isView] = true if r['table_type'] == 'VIEW'
          relation[:description] = r['table_description'] if r['table_description']
          col_name = r['column_name']
          key = case r['const']
                when 'PRIMARY KEY'
                  relation[:pkey][r['key'] || relation_name] ||= []
                when 'UNIQUE'
                  relation[:ukeys][r['key'] || "#{relation_name}.#{col_name}"] ||= []
                  # key = (relation[:ukeys] = Hash.new { |h, k| h[k] = [] }) if key.is_a?(Array)
                  # key[r['key']]
                end
          key << col_name if key
          cols = relation[:cols] # relation.fetch(:cols) { relation[:cols] = [] }
          cols[col_name] = [r['data_type'], r['max_length'], measures&.include?(col_name), r['is_nullable'] == 'NO']
          # puts "KEY! #{r['relation_name']}.#{col_name} #{r['key']} #{r['const']}" if r['key']
        end
      else # MySQL2 acts a little differently, bringing back an array for each row
        ActiveRecord::Base.retrieve_schema_and_tables(sql).each do |r|
          relation = relations[(relation_name = r[1])] # here relation represents a table or view from the database
          relation[:isView] = true if r[2] == 'VIEW' # table_type
          col_name = r[3]
          key = case r[6] # constraint type
                when 'PRIMARY KEY'
                  # key
                  relation[:pkey][r[7] || relation_name] ||= []
                when 'UNIQUE'
                  relation[:ukeys][r[7] || "#{relation_name}.#{col_name}"] ||= []
                  # key = (relation[:ukeys] = Hash.new { |h, k| h[k] = [] }) if key.is_a?(Array)
                  # key[r['key']]
                end
          key << col_name if key
          cols = relation[:cols] # relation.fetch(:cols) { relation[:cols] = [] }
          # 'data_type', 'max_length'
          cols[col_name] = [r[4], r[5], measures&.include?(col_name)]
          # puts "KEY! #{r['relation_name']}.#{col_name} #{r['key']} #{r['const']}" if r['key']
        end
      end

      # # Add unique OIDs
      # if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      #   ActiveRecord::Base.execute_sql(
      #     "SELECT c.oid, n.nspname, c.relname
      #     FROM pg_catalog.pg_namespace AS n
      #       INNER JOIN pg_catalog.pg_class AS c ON n.oid = c.relnamespace
      #     WHERE c.relkind IN ('r', 'v')"
      #   ).each do |r|
      #     next if ['pg_catalog', 'information_schema', ''].include?(r['nspname']) ||
      #       ['ar_internal_metadata', 'schema_migrations'].include?(r['relname'])
      #     relation = relations.fetch(r['relname'], nil)
      #     if relation
      #       (relation[:oid] ||= {})[r['nspname']] = r['oid']
      #     else
      #       puts "Where is #{r['nspname']} #{r['relname']} ?"
      #     end
      #   end
      # end
      # schema = ::Brick.default_schema # Reset back for this next round of fun
      case ActiveRecord::Base.connection.adapter_name
      when 'PostgreSQL', 'Mysql2'
        sql = "SELECT kcu1.CONSTRAINT_SCHEMA, kcu1.TABLE_NAME, kcu1.COLUMN_NAME,
                  kcu2.CONSTRAINT_SCHEMA AS primary_schema, kcu2.TABLE_NAME AS primary_table, kcu1.CONSTRAINT_NAME AS CONSTRAINT_SCHEMA_FK
          FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS AS rc
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu1
              ON kcu1.CONSTRAINT_CATALOG = rc.CONSTRAINT_CATALOG
              AND kcu1.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
              AND kcu1.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
            INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu2
              ON kcu2.CONSTRAINT_CATALOG = rc.UNIQUE_CONSTRAINT_CATALOG
              AND kcu2.CONSTRAINT_SCHEMA = rc.UNIQUE_CONSTRAINT_SCHEMA
              AND kcu2.CONSTRAINT_NAME = rc.UNIQUE_CONSTRAINT_NAME#{"
              AND kcu2.TABLE_NAME = kcu1.REFERENCED_TABLE_NAME
              AND kcu2.COLUMN_NAME = kcu1.REFERENCED_COLUMN_NAME" unless is_postgres }
              AND kcu2.ORDINAL_POSITION = kcu1.ORDINAL_POSITION#{"
          WHERE kcu1.CONSTRAINT_SCHEMA = COALESCE(current_setting('SEARCH_PATH'), 'public')" if is_postgres && schema }"
          # AND kcu2.TABLE_NAME = ?;", Apartment::Tenant.current, table_name
      when 'SQLite'
        sql = "SELECT m.name, fkl.\"from\", fkl.\"table\", m.name || '_' || fkl.\"from\" AS constraint_name
        FROM sqlite_master m
          INNER JOIN pragma_foreign_key_list(m.name) fkl ON m.type = 'table'
        ORDER BY m.name, fkl.seq"
      else
      end
      if sql
        # ::Brick.default_schema ||= schema ||= 'public' if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        ActiveRecord::Base.execute_sql(sql).each do |fk|
          fk = fk.values unless fk.is_a?(Array)
          # Multitenancy makes things a little more general overall, except for non-tenanted tables
          if apartment_excluded&.include?(fk[1].singularize.camelize)
            fk[0] = Apartment.default_schema
          elsif is_postgres && (fk[0] == 'public' || (is_multitenant && fk[0] == schema)) ||
                !is_postgres && ['mysql', 'performance_schema', 'sys'].exclude?(fk[0])
            fk[0] = nil
          end
          if apartment_excluded&.include?(fk[4].singularize.camelize)
            fk[3] = Apartment.default_schema
          elsif is_postgres && (fk[3] == 'public' || (is_multitenant && fk[3] == schema)) ||
                !is_postgres && ['mysql', 'performance_schema', 'sys'].exclude?(fk[3])
            fk[3] = nil
          end
          ::Brick._add_bt_and_hm(fk, relations)
        end
      end
    end

    tables = []
    views = []
    relations.each do |k, v|
      name_parts = k.split('.')
      idx = 1
      name_parts = name_parts.map do |x|
        ((idx += 1) < name_parts.length ? x.singularize : x).camelize
      end
      if v.key?(:isView)
        views
      else
        name_parts.shift if apartment && name_parts.length > 1 && name_parts.first == Apartment.default_schema
        tables
      end << name_parts.join('::')
    end
    unless tables.empty?
      puts "\nClasses that can be built from tables:"
      tables.sort.each { |x| puts x }
    end
    unless views.empty?
      puts "\nClasses that can be built from views:"
      views.sort.each { |x| puts x }
    end

    ::Brick.load_additional_references if initializer_loaded
  end

  def retrieve_schema_and_tables(sql = nil, is_postgres = nil, schema = nil)
    sql ||= "SELECT t.table_schema AS \"schema\", t.table_name AS relation_name, t.table_type,#{"
      pg_catalog.obj_description(
        ('\"' || t.table_schema || '\".\"' || t.table_name || '\"')::regclass, 'pg_class'
      ) AS table_description," if is_postgres}
      c.column_name, c.data_type,
      COALESCE(c.character_maximum_length, c.numeric_precision) AS max_length,
      tc.constraint_type AS const, kcu.constraint_name AS \"key\",
      c.is_nullable
    FROM INFORMATION_SCHEMA.tables AS t
      LEFT OUTER JOIN INFORMATION_SCHEMA.columns AS c ON t.table_schema = c.table_schema
        AND t.table_name = c.table_name
      LEFT OUTER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu ON
        -- ON kcu.CONSTRAINT_CATALOG = t.table_catalog AND
        kcu.CONSTRAINT_SCHEMA = c.table_schema
        AND kcu.TABLE_NAME = c.table_name
        AND kcu.position_in_unique_constraint IS NULL
        AND kcu.ordinal_position = c.ordinal_position
      LEFT OUTER JOIN INFORMATION_SCHEMA.table_constraints AS tc
        ON kcu.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
        AND kcu.TABLE_NAME = tc.TABLE_NAME
        AND kcu.CONSTRAINT_NAME = tc.constraint_name
    WHERE t.table_schema #{is_postgres ?
        "NOT IN ('information_schema', 'pg_catalog')"
        :
        "= '#{ActiveRecord::Base.connection.current_database.tr("'", "''")}'"}#{"
      AND t.table_schema = COALESCE(current_setting('SEARCH_PATH'), 'public')" if is_postgres && schema }
  --          AND t.table_type IN ('VIEW') -- 'BASE TABLE', 'FOREIGN TABLE'
      AND t.table_name NOT IN ('pg_stat_statements', ?, ?)
    ORDER BY 1, t.table_type DESC, 2, c.ordinal_position"
    ar_smtn = if ActiveRecord::Base.respond_to?(:schema_migrations_table_name)
                ActiveRecord::Base.schema_migrations_table_name
              else
                'schema_migrations'
              end
    ar_imtn = ActiveRecord.version >= ::Gem::Version.new('5.0') ? ActiveRecord::Base.internal_metadata_table_name : ''
    ActiveRecord::Base.execute_sql(sql, ar_smtn, ar_imtn)
  end
end

# ==========================================

# :nodoc:
module Brick
  # rubocop:disable Style/CommentedKeyword
  module Extensions
    MAX_ID = Arel.sql('MAX(id)')
    IS_AMOEBA = Gem.loaded_specs['amoeba']

    def self.included(base)
      base.send :extend, ClassMethods
    end

    # :nodoc:
    module ClassMethods

    private

    end
  end # module Extensions
  # rubocop:enable Style/CommentedKeyword

  class << self
    def _add_bt_and_hm(fk, relations, is_polymorphic = false, is_optional = false)
      bt_assoc_name = fk[2]
      unless is_polymorphic
        bt_assoc_name = if bt_assoc_name.underscore.end_with?('_id')
                          bt_assoc_name[0..-4]
                        elsif bt_assoc_name.downcase.end_with?('id') && bt_assoc_name.exclude?('_')
                          bt_assoc_name[0..-3] # Make the bold assumption that we can just peel off any final ID part
                        else
                          "#{bt_assoc_name}_bt"
                        end
      end
      bt_assoc_name = "_#{bt_assoc_name}" if bt_assoc_name == 'attribute'

      # %%% Temporary schema patch
      for_tbl = fk[1]
      apartment = Object.const_defined?('Apartment') && Apartment
      fk[0] = Apartment.default_schema if apartment && apartment.excluded_models.include?(for_tbl.singularize.camelize)
      fk[1] = "#{fk[0]}.#{fk[1]}" if fk[0] # && fk[0] != ::Brick.default_schema
      bts = (relation = relations.fetch(fk[1], nil))&.fetch(:fks) { relation[:fks] = {} }

      # %%% Do we miss out on has_many :through or even HM based on constantizing this model early?
      # Maybe it's already gotten this info because we got as far as to say there was a unique class
      primary_table = if (is_class = fk[4].is_a?(Hash) && fk[4].key?(:class))
                        pri_tbl = (primary_class = fk[4][:class].constantize).table_name
                        if (pri_tbl_parts = pri_tbl.split('.')).length > 1
                          fk[3] = pri_tbl_parts.first
                        end
                      else
                        is_schema = if ::Brick.config.schema_behavior[:multitenant]
                                      # If Apartment gem lists the primary table as being associated with a non-tenanted model
                                      # then use 'public' schema for the primary table
                                      if apartment && apartment&.excluded_models.include?(fk[4].singularize.camelize)
                                        fk[3] = Apartment.default_schema
                                        true
                                      end
                                    else
                                      fk[3] && fk[3] != ::Brick.default_schema && fk[3] != 'public'
                                    end
                        pri_tbl = fk[4]
                        is_schema ? "#{fk[3]}.#{pri_tbl}" : pri_tbl
                      end
      hms = (relation = relations.fetch(primary_table, nil))&.fetch(:fks) { relation[:fks] = {} } unless is_class

      unless (cnstr_name = fk[5])
        # For any appended references (those that come from config), arrive upon a definitely unique constraint name
        pri_tbl = is_class ? fk[4][:class].underscore : pri_tbl
        pri_tbl = "#{bt_assoc_name}_#{pri_tbl}" if pri_tbl&.singularize != bt_assoc_name
        cnstr_base = cnstr_name = "(brick) #{for_tbl}_#{pri_tbl}"
        cnstr_added_num = 1
        cnstr_name = "#{cnstr_base}_#{cnstr_added_num += 1}" while bts&.key?(cnstr_name) || hms&.key?(cnstr_name)
        missing = []
        missing << fk[1] unless relations.key?(fk[1])
        missing << primary_table unless is_class || relations.key?(primary_table)
        unless missing.empty?
          tables = relations.reject { |_k, v| v.fetch(:isView, nil) }.keys.sort
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent #{'table'.pluralize(missing.length)} #{missing.join(' and ')}. (Available tables include #{tables.join(', ')}.)"
          return
        end
        unless (cols = relations[fk[1]][:cols]).key?(fk[2]) || (is_polymorphic && cols.key?("#{fk[2]}_id") && cols.key?("#{fk[2]}_type"))
          columns = cols.map { |k, v| "#{k} (#{v.first.split(' ').first})" }
          puts "Brick: Additional reference #{fk.inspect} refers to non-existent column #{fk[2]}. (Columns present in #{fk[1]} are #{columns.join(', ')}.)"
          return
        end
        if (redundant = bts.find { |_k, v| v[:inverse]&.fetch(:inverse_table, nil) == fk[1] && v[:fk] == fk[2] && v[:inverse_table] == primary_table })
          if is_class && !redundant.last.key?(:class)
            redundant.last[:primary_class] = primary_class # Round out this BT so it can find the proper :source for a HMT association that references an STI subclass
          else
            puts "Brick: Additional reference #{fk.inspect} is redundant and can be removed.  (Already established by #{redundant.first}.)"
          end
          return
        end
      end
      return unless bts # Rails 5.0 and older can have bts end up being nil

      if (assoc_bt = bts[cnstr_name])
        if is_polymorphic
          # Assuming same fk (don't yet support composite keys for polymorphics)
          assoc_bt[:inverse_table] << fk[4]
        else # Expect we could have a composite key going
          if assoc_bt[:fk].is_a?(String)
            assoc_bt[:fk] = [assoc_bt[:fk], fk[2]] unless fk[2] == assoc_bt[:fk]
          elsif assoc_bt[:fk].exclude?(fk[2])
            assoc_bt[:fk] << fk[2]
          end
          assoc_bt[:assoc_name] = "#{assoc_bt[:assoc_name]}_#{fk[2]}"
        end
      else
        inverse_table = [primary_table] if is_polymorphic
        assoc_bt = bts[cnstr_name] = { is_bt: true, fk: fk[2], assoc_name: bt_assoc_name, inverse_table: inverse_table || primary_table }
        assoc_bt[:optional] = true if is_optional
        assoc_bt[:polymorphic] = true if is_polymorphic
      end
      if is_class
        # For use in finding the proper :source for a HMT association that references an STI subclass
        assoc_bt[:primary_class] = primary_class
        # For use in finding the proper :inverse_of for a BT association that references an STI subclass
        # assoc_bt[:inverse_of] = primary_class.reflect_on_all_associations.find { |a| a.foreign_key == bt[1] }
      end

      return if is_class || ::Brick.config.exclude_hms&.any? { |exclusion| fk[1] == exclusion[0] && fk[2] == exclusion[1] && primary_table == exclusion[2] } || hms.nil?

      if (assoc_hm = hms.fetch((hm_cnstr_name = "hm_#{cnstr_name}"), nil))
        if assoc_hm[:fk].is_a?(String)
          assoc_hm[:fk] = [assoc_hm[:fk], fk[2]] unless fk[2] == assoc_hm[:fk]
        elsif assoc_hm[:fk].exclude?(fk[2])
          assoc_hm[:fk] << fk[2]
        end
        assoc_hm[:alternate_name] = "#{assoc_hm[:alternate_name]}_#{bt_assoc_name}" unless assoc_hm[:alternate_name] == bt_assoc_name
        assoc_hm[:inverse] = assoc_bt
      else
        inv_tbl = if ::Brick.config.schema_behavior[:multitenant] && apartment && fk[0] == Apartment.default_schema
                    for_tbl
                  else
                    fk[1]
                  end
        assoc_hm = hms[hm_cnstr_name] = { is_bt: false, fk: fk[2], assoc_name: for_tbl.pluralize, alternate_name: bt_assoc_name,
                                          inverse_table: inv_tbl, inverse: assoc_bt }
        assoc_hm[:polymorphic] = true if is_polymorphic
        hm_counts = relation.fetch(:hm_counts) { relation[:hm_counts] = {} }
        hm_counts[fk[1]] = hm_counts.fetch(fk[1]) { 0 } + 1
      end
      assoc_bt[:inverse] = assoc_hm
    end

    # Identify built out routes, migrations, models,
    # (and also soon controllers and views!)
    # for each resource
    def get_status_of_resources
      rails_root = ::Rails.root.to_s
      migrations = if Dir.exist?(mig_path = ActiveRecord::Migrator.migrations_paths.first || "#{rails_root}/db/migrate")
                     Dir["#{mig_path}/**/*.rb"].each_with_object(Hash.new { |h, k| h[k] = [] }) do |v, s|
                       File.read(v).split("\n").each do |line|
                         # For all non-commented lines, look for any that have "create_table", "alter_table", or "drop_table"
                         if !line.lstrip.start_with?('#') &&
                            (idx = (line.index('create_table ') || line.index('create_table('))&.+(13)) ||
                            (idx = (line.index('alter_table ') || line.index('alter_table('))&.+(12)) ||
                            (idx = (line.index('drop_table ') || line.index('drop_table('))&.+(11))
                           tbl = line[idx..-1].match(/([:'"\w\.]+)/)&.captures&.first
                           if tbl
                             s[tbl.tr(':\'"', '').pluralize] << v
                             break
                           end
                         end
                       end
                     end
                   end
      if ::ActiveSupport.version < ::Gem::Version.new('6') ||
         ::Rails.configuration.instance_variable_get(:@autoloader) == :classic
        Rails.configuration.eager_load_namespaces.select { |ns| ns < Rails::Application }.each(&:eager_load!)
      else
        Zeitwerk::Loader.eager_load_all
      end
      abstract_activerecord_bases = ActiveRecord::Base.descendants.select { |ar| ar.abstract_class? }.map(&:name)
      # abstract_activerecord_bases << ActiveRecord::Base
      models = if Dir.exist?(model_path = "#{rails_root}/app/models")
                 Dir["#{model_path}/**/*.rb"].each_with_object({}) do |v, s|
                   File.read(v).split("\n").each do |line|
                     # For all non-commented lines, look for any that start with "class " and also "< ApplicationRecord"
                     if line.lstrip.start_with?('class') && (idx = line.index('class'))
                       model = line[idx + 5..-1].match(/[\s:]+([\w:]+)/)&.captures&.first
                       if model && abstract_activerecord_bases.exclude?(model)
                         klass = begin
                                   model.constantize
                                 rescue
                                 end
                         s[model.underscore.tr('/', '.').pluralize] = [
                           v.start_with?(rails_root) ? v[rails_root.length + 1..-1] : v,
                           klass
                         ]
                       end
                     end
                   end
                 end
               end
      ::Brick.relations.keys.map { |v| [(r = v.pluralize), (model = models[r])&.last&.table_name || v, migrations&.fetch(r, nil), model&.first] }
    end

    # Locate orphaned records
    def find_orphans(multi_schema)
      is_default_schema = multi_schema&.==(Apartment.default_schema)
      relations.each_with_object([]) do |v, s|
        frn_tbl = v.first
        next if (relation = v.last).key?(:isView) || config.exclude_tables.include?(frn_tbl) ||
                !(for_pk = (relation[:pkey].values.first&.first))

        is_default_frn_schema = !is_default_schema && multi_schema &&
                                ((frn_parts = frn_tbl.split('.')).length > 1 && frn_parts.first)&.==(Apartment.default_schema)
        relation[:fks].select { |_k, assoc| assoc[:is_bt] }.each do |_k, bt|
          begin
            if bt.key?(:polymorphic)
              pri_pk = for_pk
              pri_tables = Brick.config.polymorphics["#{frn_tbl}.#{bt[:fk]}"]
                                .each_with_object(Hash.new { |h, k| h[k] = [] }) do |pri_class, s|
                s[Object.const_get(pri_class).table_name] << pri_class
              end
              fk_id_col = "#{bt[:fk]}_id"
              fk_type_col = "#{bt[:fk]}_type"
              selects = []
              pri_tables.each do |pri_tbl, pri_types|
                # Skip if database is multitenant, we're not focused on "public", and the foreign and primary tables
                # are both in the "public" schema
                next if is_default_frn_schema &&
                        ((pri_parts = pri_tbl&.split('.'))&.length > 1 && pri_parts.first)&.==(Apartment.default_schema)

                selects << "SELECT '#{pri_tbl}' AS pri_tbl, frn.#{fk_type_col} AS pri_type, frn.#{fk_id_col} AS pri_id, frn.#{for_pk} AS frn_id
                FROM #{frn_tbl} AS frn
                  LEFT OUTER JOIN #{pri_tbl} AS pri ON pri.#{pri_pk} = frn.#{fk_id_col}
                WHERE frn.#{fk_type_col} IN (#{
                  pri_types.map { |pri_type| "'#{pri_type}'" }.join(', ')
                }) AND frn.#{bt[:fk]}_id IS NOT NULL AND pri.#{pri_pk} IS NULL\n"
              end
              ActiveRecord::Base.execute_sql(selects.join("UNION ALL\n")).each do |o|
                entry = [frn_tbl, o['frn_id'], o['pri_type'], o['pri_id'], fk_id_col]
                entry << o['pri_tbl'] if (pri_class = Object.const_get(o['pri_type'])) != pri_class.base_class
                s << entry
              end
            else
              # Skip if database is multitenant, we're not focused on "public", and the foreign and primary tables
              # are both in the "public" schema
              pri_tbl = bt.key?(:inverse_table) && bt[:inverse_table]
              next if is_default_frn_schema &&
                      ((pri_parts = pri_tbl&.split('.'))&.length > 1 && pri_parts.first)&.==(Apartment.default_schema)

              pri_pk = relations[pri_tbl].fetch(:pkey, nil)&.values&.first&.first ||
                       _class_pk(pri_tbl, multi_schema)
              ActiveRecord::Base.execute_sql(
                "SELECT frn.#{bt[:fk]} AS pri_id, frn.#{for_pk} AS frn_id
                FROM #{frn_tbl} AS frn
                  LEFT OUTER JOIN #{pri_tbl} AS pri ON pri.#{pri_pk} = frn.#{bt[:fk]}
                WHERE frn.#{bt[:fk]} IS NOT NULL AND pri.#{pri_pk} IS NULL
                ORDER BY 1, 2"
              ).each { |o| s << [frn_tbl, o['frn_id'], pri_tbl, o['pri_id'], bt[:fk]] }
            end
          rescue StandardError => err
            puts "Strange -- #{err.inspect}"
          end
        end
      end
    end

    def _class_pk(dotted_name, multitenant)
      Object.const_get((multitenant ? [dotted_name.split('.').last] : dotted_name.split('.')).map { |nm| "::#{nm.singularize.camelize}" }.join).primary_key
    end
  end
end
