class Slot
  module NoControllerHelpers
    def protect_against_forgery?
      # FIXME
      false
    end

    def logged_in?
      !(User.current_user.nil? || User.current_user.login == 'anon')
    end
  end

  cattr_accessor :max_char_count, :current_slot
  self.max_char_count = 200
  attr_reader :card, :action, :template
  attr_writer :form 
  attr_accessor  :options_need_save, :state, :requested_view, :js_queue_initialized,  
    :position, :renderer, :form, :superslot, :char_count, :item_format, :type, :renders, 
    :start_time, :skip_autosave, :config, :slot_options, :render_args, :context

  VIEW_ALIASES = { 
    :view => :open,
    :card => :open,
    :line => :closed,
  }
       
  class << self
    def render_content content, opts = {}
      Slot.current_slot = nil
      view = opts.delete(:view)
      view = :naked unless view && !view.blank?
      tmp_card = Card.new :name=>"__tmp_card__", :content => content 
      Slot.new(tmp_card, "main_1", view, nil, opts).render(view)
    end
  end
   
  def initialize(card, context="main_1", action="view", template=nil, opts={} )
    @card, @context, @action, @template = card, context.to_s, action.to_s, template
    Slot.current_slot ||= self
    
    @template ||= begin
      t = ActionView::Base.new( CardController.view_paths, {} )
      t.helpers.send :include, CardController.master_helper_module
      t.helpers.send :include, NoControllerHelpers
      t
    end
    # FIXME: this and context should all be part of the context object, I think.
    # In any case I had to use "slot_options" rather than just options to avoid confusion with lots of 
    # local variables named options.
    @slot_options = {
      :relative_content => {},
      :main_content => nil,
      :main_card => nil,
      :inclusion_view_overrides => nil,
      :params => {},
      :renderer => Renderer.new,
      :base => nil
    }.merge(opts)
    
    @renderer = @slot_options[:renderer]
    @context = "main_1" unless @context =~ /\_/
    @position = @context.split('_').last    
    @char_count = 0
    @subslots = []  
    @state = 'view'
    @renders = {}
    @js_queue_initialized = {}
  end

  def subslot(card, context_base=nil, &proc)
    # Note that at this point the subslot context, and thus id, are
    # somewhat meaningless-- the subslot is only really used for tracking position.
    context_base ||= self.context
    new_position = @subslots.size + 1
    new_slot = self.class.new(card, "#{context_base}_#{new_position}", @action, @template, :renderer=>@renderer)

    new_slot.state = @state
    new_slot.superslot = self
    new_slot.position = new_position
    
    @subslots << new_slot 
    new_slot
  end
    
  def root
    superslot ? superslot.root : self
  end

  def form
    @form ||= begin
      # NOTE this code is largely copied out of rails fields_for
      options = {} # do I need any? #args.last.is_a?(Hash) ? args.pop : {}
      block = Proc.new {}
      builder = options[:builder] || ActionView::Base.default_form_builder
      card.name.gsub!(/^#{Regexp.escape(root.card.name)}\+/, '+') if root.card.new_record?  ##FIXME -- need to match other relative inclusions.
      fields_for = builder.new("cards[#{card.name.pre_cgi}]", card, @template, options, block)       
    end
  end    
  
  def full_field_name(field)   
    form.text_field(field).match(/name=\"([^\"]*)\"/)[1] 
  end

 
  def js
    @js ||= SlotJavascript.new(self)
  end
         
  # FIXME: passing a block seems to only work in the templates and not from
  # internal slot calls, so I added the option passing internal content which
  # makes all the ugly block_given? ifs..                                                 
  def wrap(action="", args={}) 
    render_slot = args.key?(:add_slot) ? args.delete(:add_slot) : !xhr? 
    content = args.delete(:content)
     
    open_slot, close_slot = "",""

    result = ""
    if render_slot
      case action.to_s
        when 'content';    css_class = 'transcluded'
        when 'exception';  css_class = 'exception'    
        else begin
          css_class = 'card-slot '      
          css_class << (action=='closed' ? 'line' : 'paragraph')
        end
      end       
      
      css_class << " " + Wagn::Pattern.css_names( card ) if card
      
      attributes = { 
        :cardId   => (card && card.id),
        :style    => args[:style],
        :view     => args[:view],
        :item     => args[:item],
        :base     => args[:base], # deprecated
        :class    => css_class,
        :position => UUID.new.generate.gsub(/^(\w+)0-(\w+)-(\w+)-(\w+)-(\w+)/,'\1')
      }
      
      slot_attr = attributes.map{ |key,value| value && %{ #{key}="#{value}" }  }.join
      open_slot = "<div #{slot_attr}>"
      close_slot= "</div>"
    end
    
    if block_given? 
      if (Rails::VERSION::MAJOR >=2 && Rails::VERSION::MINOR >= 2)
        args = nil
        @template.output_buffer ||= ''   # fixes error in CardControllerTest#test_changes
      else
        args = proc.binding
      end
      @template.concat open_slot, *args
      yield(self)
      @template.concat close_slot, *args
      return ""
    else
      return open_slot + content + close_slot
    end
  end
  
  def cache_action(cc_method) 
    (if CachedCard===card 
      card.send(cc_method) || begin
        cached_card, @card = card, Card.find_by_key_and_trash(card.key, false)
        if !@card
          return "Oops! found cached card for #{card.key} but couln't find the real one"
        end
        content = yield(@card)
        cached_card.send("#{cc_method}=", content.clone)  
        content
      end
    else
      yield(card)
    end).clone
  end
  
  def wrap_content( content="" )
    %{<span class="#{canonicalize_view(self.requested_view)}-content content editOnDoubleClick">} +
    content.to_s + 
    %{</span><!--[if IE]>&nbsp;<![endif]-->} 
  end    

  def wrap_main(content)
    return content if p=root.slot_options[:params] and p[:layout]=='none'
    %{<div id="main" context="main">#{content}</div>}
  end
  
  def deny_render?(action)
    case
      when [:deny_view, :edit_auto, :open_missing, :closed_missing].member?(action);
        false
      when card.new_record?
        false # need create check...
      when [:edit, :edit_in_form, :multi_edit].member?(action)
        !card.ok?(:edit) and :deny_view #should be deny_edit
      else
        !card.ok?(:read) and :deny_view
    end
  end

  def canonicalize_view( view )
    view = view.to_sym
    VIEW_ALIASES[view.to_sym] || view
  end

  def count_render
    root.renders[card.name] ||= 1 
    root.renders[card.name] += 1 
  end
  
  def too_many_renders?
    root.renders[card.name] ||= 1 
    root.renders[card.name] > System.max_renders 
  end

  def render(action, args={})      
    Rails.logger.debug "Slot(#{card.name}).render #{action}"
    self.render_args = args.clone
    count_render unless [:name, :link].member?(action)
    ok_action = case
      when too_many_renders?;   :too_many_renders
      when denial = deny_render?(action) ; denial
      else                               ; action
    end

    w_content = nil
    result = case ok_action

    ###-----------( FULL )
      when :new
        w_content = render_partial('views/new')
      
      when :open, :view, :card
        @state = :view; self.requested_view = 'open'
        w_action = 'open'
        w_content = render_partial('views/open')

      when :closed, :line    
        @state = :line; w_action='closed'; self.requested_view = 'closed'
        w_content = render_partial('views/closed')  # --> slot.wrap_content slot.render( :expanded_line_content )   
         
      when :setting  
        w_action = self.requested_view = 'content'
        w_content = render_partial('views/setting')  
      
    ###----------------( NAME)
    
      when :link;  # FIXME -- this processing should be unified with standard link processing imho
        opts = {:class=>"cardname-link #{(card.new_record? && !card.virtual?) ? 'wanted-card' : 'known-card'}"}
        opts[:type] = slot.type if slot.type 
        link_to_page card.name, card.name, opts
      when :name;     card.name
      when :key;      card.name.to_key
      when :linkname; Cardname.escape(card.name)
      when :titled;   content_tag( :h1, less_fancy_title(card.name) ) + self.render( :content )
      when :rss_titled;                                                         
        # content includes wrap  (<object>, etc.) , which breaks at least safari rss reader.
        content_tag( :h2, less_fancy_title(card.name) ) + self.render( :expanded_view_content )


   ###----------------( CHANGES)

      when :change;
        w_action = self.requested_view = 'content'
        w_content = render_partial('views/change')
      when :rss_change
        w_action = self.requested_view = 'content'
        render_partial('views/change')
        

    ###---(  CONTENT VARIATIONS ) 
      #-----( with transclusions processed      
      when :content
        w_action = self.requested_view = 'content'  
        c = render_expanded_view_content
        w_content = wrap_content(((c.size < 10 && strip_tags(c).blank?) ? "<span class=\"faint\">--</span>" : c))
          
      when :expanded_view_content, :naked, :bare; self.render_expanded_view_content
      when :expanded_line_content; self.render_expanded_line_content
      when :closed_content;  self.render_closed_content 
      when :open_content; self.render_open_content
      when :naked_content; self.render_naked_content
      when :array;  render_array;
      when :wdiff;  render_wdiff;
      when :raw; card.content  

      when :expanded_view_content, :naked 
        @state = 'view'
        expand_inclusions(  cache_action('view_content') {  card.post_render( render(:open_content)) } )

      when :expanded_line_content
        expand_inclusions(  cache_action('line_content') { render(:closed_content) } )

    ###---(  EDIT VIEWS ) 
      when :edit;  
        @state=:edit
        # FIXME CONTENT: the hard template test can go away when we phase out the old system.
        if card.content_templated?
          render(:multi_edit)
        else
          content_field(slot.form)
        end
        
      when :multi_edit;
        @state=:edit 
        args[:add_javascript]=true
        hidden_field_tag( :multi_edit, true) +
        expand_inclusions( render(:naked_content) )

      when :edit_in_form
        render_partial('views/edit_in_form', args.merge(:form=>form))
    
      ###---(  EXCEPTIONS ) 
      
      when :deny_view, :edit_auto, :too_slow, :too_many_renders, :open_missing, :closed_missing, :setting_missing
          render_partial("views/#{ok_action}", args)

      when :blank; 
        ""

      else; "<strong>#{card.name} - unknown card view: '#{ok_action}'</strong>"
    end
    if w_content
      args[:add_slot] = true unless args.key?(:add_slot)
      result = wrap(w_action, { :content=>w_content }.merge(args))
    end
    
#      result ||= "" #FIMXE: wtf?
    result << javascript_tag("setupLinksAndDoubleClicks();") if args[:add_javascript]
    result.strip
  rescue Card::PermissionDenied=>e
    return "Permission error: #{e.message}"
  end

  
  def render_expanded_view_content
    @state = 'view'
    expand_inclusions(  cache_action('view_content') {  
      card.post_render( render_open_content) 
    })
  end
  
  def render_expanded_line_content
    expand_inclusions(  cache_action('line_content') { render_closed_content } )
  end
  
  def render_closed_content
    if generic_card? 
      truncatewords_with_closing_tags( render_open_content )
    else
      render_card_partial(:line)   # in basic case: --> truncate( slot.render( :open_content ))
    end
  end
  
  def render_wdiff
    DiffPatch # hack, autotload CardMerger
    count_render
    if too_many_renders?
      return render_partial( 'views/too_many_renders' ) 
    end
    
    names = case card.type 
      when 'Search';    Wql.new(card.get_spec(:return => 'name_content')).run.keys
      when 'Pointer';    card.pointees
      else  card.name
    end
    
    inner_content = CardMerger.dump( names )
    "<form><textarea rows=20 cols=50>#{inner_content}</textarea></form>"
  end  
  
  def render_array
    Rails.logger.debug "Slot(#{card.name}).render_array   root = #{root}"
    
    count_render
    if too_many_renders?
      return render_partial( 'views/too_many_renders' ) 
    end
    case card.type 
      when 'Search'
        names = Wql.new(card.get_spec(:return => 'name_content')).run.keys
        names.map{|x| subslot(CachedCard.get(x)).render(:naked) }.inspect
      when 'Pointer'
        card.pointees.map{|x| subslot(CachedCard.get(x)).render(:naked) }.inspect
      else
        [render_expanded_view_content].inspect
    end
  end
  
  def render_open_content
    if generic_card?
      render_naked_content
    else
      render_card_partial(:content)  # FIXME?: 'content' is inconsistent
    end
  end
  
  def generic_card?
    # FIXME: this could be *much* better.  going for 80/20.
    card.type == 'Basic' || card.type == 'Phrase'
  end
  
  def render_naked_content
    if card.virtual? and card.builtin?  # virtual? test will filter out cached cards (which won't respond to builtin)
      template.render :partial => "builtin/#{card.name.gsub(/\*/,'')}" 
    else
      cache_action('naked_content') do
        #passed_in_content = args.delete(:content) # Can we get away without this??
        templated_content = card.content_templated? ? card.setting('content') : nil
        renderer_content = templated_content || ""
        @renderer.render( card, renderer_content, update_refs=card.references_expired)
      end
    end
  end

  def sterilize_inclusion(content)
    content.gsub(/\{\{/,'{<bogus />{').gsub(/\}\}/,'}<bogus />}')
    # KLUGILICIOIUS:  when don't want inclusions rendered, we can't leave the {{}} intact or an outer card 
    # could expand them (often weirdly). The <bogus> thing seems to work ok for now.
  end

  def expand_inclusions(content, args={})
    if card.name.template_name? or (card.name.email_config_name? and !slot_options[:base])
      return sterilize_inclusion(content) 
    end
    newcontent = content.gsub(Chunk::Transclude::TRANSCLUDE_PATTERN) do
      expand_inclusion($~)
    end
    newcontent
  end 
  
  def expand_inclusion(match)   
    return '' if (@state==:line && self.char_count > Slot.max_char_count) # Don't bother processing inclusion if we're already out of view
    tname, options = Chunk::Transclude.parse(match)
    
    case tname
    when /^\#\#/                 ; return ''                      #invisible comment
    when /^\#/ || nil? || blank? ; return "<!-- #{CGI.escapeHTML match[1]} -->"    #visible comment
    when '_main'
      if content=slot_options[:main_content] and content!='~~render main inclusion~~'
        return wrap_main(slot_options[:main_content]) 
      end  
      tcard=slot_options[:main_card] 
      item  = symbolize_param(:item) and options[:item] = item
      pview = symbolize_param(:view) and options[:view] = pview
      self.context = options[:context] = 'main'
      options[:view] ||= :open
    end  
         
    options[:view] ||= (self.context == "layout_0" ? :naked : :content)
    options[:view] = get_inclusion_view(options[:view])
    options[:fullname] = fullname = get_inclusion_fullname(tname,options)
    options[:showname] = tname.to_show(fullname)
    
    tcard ||= (@state==:edit ?
      ( Card.find_by_name(fullname) || 
        Card.find_virtual(fullname) || 
        Card.new(new_inclusion_card_args(tname, options))
      ) :
      ( slot_options[:base].respond_to?(:name) && slot_options[:base].name == fullname ?
        slot_options[:base] : CachedCard.get(fullname)
      )
    )

    tcontent = process_inclusion( tcard, options )
    tcontent = resize_image_content(tcontent, options[:size]) if options[:size]

    self.char_count += (tcontent ? tcontent.length : 0)  #should we be stripping html here?
    tname=='_main' ? wrap_main(tcontent) : tcontent
  rescue Card::PermissionDenied
    ''
  end
  
  def get_inclusion_fullname(name,options)
    fullname = name+'' #weird.  have to do this or the tname gets busted in the options hash!!
    sob = slot_options[:base]
    context = case
    when sob; (sob.respond_to?(:name) ? sob.name : sob)
    when options[:base]=='parent' 
      card.parent_name
    else
      card.name
    end
    fullname = fullname.to_absolute(context)
    fullname.gsub!('_user') { User.current_user.cardname }
    fullname = fullname.particle_names.map do |x| 
      if x =~ /^_/ and root.slot_options[:params] and root.slot_options[:params][x]
        CGI.escapeHTML( root.slot_options[:params][x] )
      else x end
    end.join("+")
    fullname
  end

  def get_inclusion_view(view)
    if map = root.slot_options[:inclusion_view_overrides] and translation = map[ canonicalize_view( view )]
      translation
    else; view; end
  end

  def get_inclusion_content(cardname)
    parameters = root.slot_options[:relative_content]
    content = parameters[cardname.gsub(/\+/,'_')]
    
    # CLEANME This is a hack to get it so plus cards re-populate on failed signups
    if parameters['cards'] and card_params = parameters['cards'][cardname.gsub('+','~plus~')]  
      content = card_params['content']
    end  
    content if content.present?  #not sure I get why this is necessary - efm
  end

  def new_inclusion_card_args(tname, options)
    args = { 
      :name=>options[:fullname], 
      :type=>options[:type] 
    }
    if content=get_inclusion_content(tname)
      args[:content]=content 
    end
    args
  end

  def resize_image_content(content, size)
    size = (size.to_s == "full" ? "" : "_#{size}")
    content.gsub(/_medium(\.\w+\")/,"#{size}"+'\1')
  end
     
  def render_partial( partial, locals={} )
    @template.render(:partial=>partial, :locals=>{ :card=>card, :slot=>self }.merge(locals))
  end

  def card_partial(action) 
    # FIXME: I like this method name better- maybe other calls should resolve here instead
    partial_for_action(action, card)
  end
  
  def render_card_partial(action, locals={})
     render_partial card_partial(action), locals
  end
  
  def process_inclusion( card, options={} )  
    #warn("<process_inclusion card=#{card.name} options=#{options.inspect}")
    subslot = subslot(card, options[:context])
    old_slot, Slot.current_slot = Slot.current_slot, subslot

    # set item_format;  search cards access this variable when rendering their content.
    subslot.item_format = options[:item] if options[:item]
    subslot.type = options[:type] if options[:type]
                           
    # FIXME! need a different test here   
    new_card = card.new_record? && !card.virtual?
    
    state, vmode = @state.to_sym, (options[:view] || :content).to_sym      
    subslot.requested_view = vmode
    action = case
      when [:name, :link, :linkname].member?(vmode)  ; vmode
      when state==:edit       ; card.virtual? ? :edit_auto : :edit_in_form   
      when new_card                       
        case   
          when vmode==:naked  ; :blank
          when vmode==:setting; :setting_missing
          when state==:line   ; :closed_missing
          else                ; :open_missing
        end
      when state==:line       ; :expanded_line_content
      else                    ; vmode
    end

    result = subslot.render action, options
    Slot.current_slot = old_slot
    result
  rescue
    %{<span class="inclusion-error">error rendering #{link_to_page card.name}</span>}
  end   
  
  def method_missing(method_id, *args, &proc) 
    # silence Rails 2.2.2 warning about binding argument to concat.  tried detecting rails 2.2
    # and removing the argument but it broken lots of integration tests.
    ActiveSupport::Deprecation.silence { @template.send(method_id, *args, &proc) }
  end

  #### --------------------  additional helpers ---------------- ###
  def render_diff(card, *args)
    @renderer.render_diff(card, *args)
  end
  
  def notice 
    # this used to access controller.notice, but as near I can tell
    # nothing ever assigns to controller.notice, so I took it away.
    # entries in flash[:notice] would be more appropriate in the page-wide
    # alert area. a quick javascript hack to have this put them there resulted in
    # odd behavior so leaving it off for now -LWH
    %{<span class="notice"></span>}
  end

  def id(area="") 
    area, id = area.to_s, ""  
    id << "javascript:#{get(area)}"
  end  
  
  def parent
    "javascript:getSlotSpan(getSlotSpan(this).parentNode)"
  end                       
   
  def nested_context?
    context.split('_').length > 2
  end
   
  def get(area="")
    area.empty? ? "getSlotSpan(this)" : "getSlotElement(this, '#{area}')"
  end
   
  def selector(area="")   
    "getSlotFromContext('#{context}')";
  end             
 
  def card_id
    (card.new_record? && card.name)  ? Cardname.escape(card.name) : card.id
  end

  def editor_id(area="")
    area, eid = area.to_s, ""
    eid << context
    eid << (area.blank? ? '' : "-#{area}")
  end

  def edit_submenu(on)
    div(:class=>'submenu') do
      [[ :content,    true  ],
       [ :name,       true, ],
       [ :type,       !(card.type_template? || (card.type=='Cardtype' and ct=card.me_type and !ct.find_all_by_trash(false).empty?))],
       [ :codename,   (System.always_ok? && card.type=='Cardtype')],
       [ :inclusions, !(card.out_transclusions.empty? || card.template? || card.hard_template),         {:inclusions=>true} ]
       ].map do |key,ok,args|

        link_to_remote( key, 
          { :url=>url_for("card/edit", args, key), :update => ([:name,:type,:codename].member?(key) ? id('card-body') : id) }, 
          :class=>(key==on ? 'on' : '') 
        ) if ok
      end.compact.join       
     end  
  end
  
  def options_submenu(on)
    div(:class=>'submenu') do
      [:permissions, :settings].map do |key|
        link_to_remote( key, 
          { :url=>url_for("card/options", {}, key), :update => id }, 
          :class=>(key==on ? 'on' : '') 
        )
      end.join
    end
  end
    
  def paging_params
    s = {}
    if p = root.slot_options[:params]
      [:offset,:limit].each{|key| s[key] = p.delete(key)}
    end
    s[:offset] = s[:offset] ? s[:offset].to_i : 0
  	s[:limit]  = s[:limit]  ? s[:limit].to_i  : (main_card? ? 50 : 20)
	  s
  end

  def main_card?
    context=~/^main_\d$/
  end

  def url_for(url, args=nil, attribute=nil)
    # recently changed URI.escape to CGI.escape to address question mark issue, but I'm still concerned neither is perfect
    # so long as we keep doing the weird Cardname.escape thing.  
    url = "javascript:'/#{url}"
    url << "/#{escape_javascript(CGI.escape(card_id.to_s))}" if (card and card_id)
    url << "/#{attribute}" if attribute   
    url << "?context='+getSlotContext(this)"
    url << "+'&' + getSlotOptions(this)"
    url << ("+'"+ args.map{|k,v| "&#{k}=#{escape_javascript(CGI.escape(v.to_s))}"}.join('') + "'") if args
    url
  end

  def header 
    @template.render :partial=>'card/header', :locals=>{ :card=>card, :slot=>self }
  end

  def menu   
    if card.virtual?
      return %{<span class="card-menu faint">Virtual</span>\n}
    end
    menu = %{<span class="card-menu">\n}
    menu << %{<span class="card-menu-left">\n}
  	menu << link_to_menu_action('view')
  	menu << link_to_menu_action('changes')
  	menu << link_to_menu_action('options') 
  	menu << link_to_menu_action('related')
  	menu << "</span>"
    
  	menu << link_to_menu_action('edit') 
  	
    
    menu << "</span>"
  end

  def footer 
    render_partial 'card/footer' 
  end
            
  def footer_links
    cache_action('footer') { 
      render_partial( 'card/footer_links' )   # this is ugly reusing this cache code
    }
  end     
  
  def option( args={}, &proc)
    args[:label] ||= args[:name]
    args[:editable]= true unless args.has_key?(:editable)
    self.options_need_save = true if args[:editable]
    concat %{<tr>
      <td class="inline label"><label for="#{args[:name]}">#{args[:label]}</label></td>
      <td class="inline field">
    }, proc.binding
    yield
    concat %{
      </td>
      <td class="help">#{args[:help]}</td>
      </tr>
    }, proc.binding
  end

  def option_header(title)
    %{<tr><td colspan="3" class="option-header"><h2>#{title}</h2></td></tr>}
  end

  def link_to_menu_action( to_action)
    menu_action = (%w{ show update }.member?(action) ? 'view' : action)
    content_tag( :li, link_to_action( to_action.capitalize, to_action, {} ),
      :class=> (menu_action==to_action ? 'current' : ''))
  end

  def link_to_action( text, to_action, remote_opts={}, html_opts={})
    link_to_remote text, {
      :url=>url_for("card/#{to_action}"),
      :update => id
    }.merge(remote_opts), html_opts
  end

  def button_to_action( text, to_action, remote_opts={}, html_opts={})
    if remote_opts.delete(:replace)
      r_opts =  { :url=>url_for("card/#{to_action}", :replace=>id ) }.merge(remote_opts)
    else
      r_opts =  { :url=>url_for("card/#{to_action}" ), :update => id }.merge(remote_opts)
    end
    button_to_remote( text, r_opts, html_opts )
  end

  def name_field(form,options={})
    form.text_field( :name, { :class=>'field card-name-field', :autocomplete=>'off'}.merge(options))
  end


  def cardtype_field(form,options={})
    @template.select_tag('card[type]', cardtype_options_for_select(card.type), options) 
  end

  def update_cardtype_function(options={})
    fn = ['File','Image'].include?(card.type) ? 
            "Wagn.onSaveQueue['#{context}']=[];" :
            "Wagn.runQueue(Wagn.onSaveQueue['#{context}']); "      
    fn << remote_function( options )   
  end
     
  def js_content_element 
    @card.hard_template ? "" : ",getSlotElement(this,'form').elements['card[content]']" 
  end

  def content_field(form,options={})   
    self.form = form              
    @nested = options[:nested]
    pre_content =  (card and !card.new_record?) ? form.hidden_field(:current_revision_id, :class=>'current_revision_id') : ''
    editor_partial = (card.type=='Pointer' ? ((c=card.setting('input'))  ? c.gsub(/[\[\]]/,'') : 'list') : 'editor')    
    pre_content + clear_queues + self.render_partial( card_partial(editor_partial), options ) + setup_autosave 
  end                          
 
  def clear_queues
    queue_context = get_queue_context

    return '' if root.js_queue_initialized.has_key?(queue_context) 
    root.js_queue_initialized[queue_context]=true

    javascript_tag(
      "Wagn.onSaveQueue['#{queue_context}']=[];\n"+
      "Wagn.onCancelQueue['#{queue_context}']=[];"
    )
  end

 
  def save_function 
    "if(ds=Wagn.draftSavers['#{context}']){ds.stop()}; if (Wagn.runQueue(Wagn.onSaveQueue['#{context}'])) { } else {return false}"
  end

  def cancel_function 
    "if(ds=Wagn.draftSavers['#{context}']){ds.stop()}; Wagn.runQueue(Wagn.onCancelQueue['#{context}']);"
  end

  def xhr?
    controller && controller.request.xhr?
  end
  
  def get_queue_context
    #FIXME: this looks like it won't work for arbitraritly nested forms.  1-level only
    @nested ? context.split('_')[0..-2].join('_') : context
  end

  def editor_hooks(hooks)
    # it seems as though code executed inline on ajax requests works fine
    # to initialize the editor, but when loading a full page it fails-- so
    # we run it in an onLoad queue.  the rest of this code we always run
    # inline-- at least until that causes problems.    
    
    queue_context = get_queue_context
    code = ""
    if hooks[:setup]
      code << "Wagn.onLoadQueue.push(function(){\n" unless xhr?
      code << hooks[:setup]
      code << "});\n" unless xhr?
    end
    if hooks[:save]  
      code << "Wagn.onSaveQueue['#{queue_context}'].push(function(){\n #{hooks[:save]} \n });\n"
    end
    if hooks[:cancel]
      code << "Wagn.onCancelQueue['#{queue_context}'].push(function(){\n #{hooks[:cancel]} \n });\n"
    end
    javascript_tag code
  end                   
  
  def setup_autosave
    if @nested or skip_autosave 
      ""
    else
      javascript_tag "Wagn.setupAutosave('#{card.id}', '#{context}');\n"
    end
  end
          
  def half_captcha
    if captcha_required?
      key = card.new_record? ? "new" : card.key
      javascript_tag(%{loadScript("http://api.recaptcha.net/js/recaptcha_ajax.js")}) +
        recaptcha_tags( :ajax=>true, :display=>{:theme=>'white'}, :id=>key)
    end
  end
  
  def full_captcha
    if captcha_required?
      key = card.new_record? ? "new" : card.key          
        recaptcha_tags( :ajax=>true, :display=>{:theme=>'white'}, :id=>key ) +
          javascript_tag(   
            %{jQuery.getScript("http://api.recaptcha.net/js/recaptcha_ajax.js", function(){
              document.getElementById('dynamic_recaptcha-#{key}').innerHTML='<span class="faint">loading captcha</span>'; 
              Recaptcha.create('#{ENV['RECAPTCHA_PUBLIC_KEY']}', document.getElementById('dynamic_recaptcha-#{key}'),RecaptchaOptions);
            });
          })
    end
  end
  
  ### ------  from wagn_helper ----
  def partial_for_action( name, card=nil )
    # FIXME: this should look up the inheritance hierarchy, once we have one
    # wow this is a steaming heap of dung.
    cardtype = (card ? card.type : 'Basic').underscore
    if Rails::VERSION::MAJOR >=2 && Rails::VERSION::MINOR <=1
      finder.file_exists?("/types/#{cardtype}/_#{name}") ?
        "/types/#{cardtype}/#{name}" :
        "/types/basic/#{name}"
    elsif   Rails::VERSION::MAJOR >=2 && Rails::VERSION::MINOR > 2
      ## This test works for .rhtml files but seems to fail on .html.erb
      begin
        @template.view_paths.find_template "types/#{cardtype}/_#{name}"
        "types/#{cardtype}/#{name}"
      rescue ActionView::MissingTemplate => e
        "/types/basic/#{name}"
      end
    else
      @template.view_paths.find { |template_path| template_path.paths.include?("types/#{cardtype}/_#{name}") } ?
        "/types/#{cardtype}/#{name}" :
        "/types/basic/#{name}"
    end
  end
  
end   

