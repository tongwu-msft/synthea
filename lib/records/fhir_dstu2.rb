module Synthea
  module Output
    module FhirDstu2Record
      def self.convert_to_fhir(entity, end_time = Time.now)
        synthea_record = entity.record_synthea
        indices = { observations: 0, conditions: 0, procedures: 0, immunizations: 0, careplans: 0, medications: 0 }
        fhir_record = FHIR::DSTU2::Bundle.new
        fhir_record.type = 'collection'
        patient = basic_info(entity, fhir_record, end_time)
        synthea_record.encounters.each do |encounter|
          curr_encounter = encounter(encounter, fhir_record, patient)
          encounter_end = encounter['end_time'] || synthea_record.patient_info[:deathdate] || end_time
          # if an encounter doesn't have an end date, either the patient died during the encounter, or they are still in the encounter
          [:conditions, :observations, :procedures, :immunizations, :careplans, :medications].each do |attribute|
            entry = synthea_record.send(attribute)[indices[attribute]]
            while entry && entry['time'] <= encounter_end
              method = entry['fhir']
              method = attribute.to_s if method.nil?
              send(method, entry, fhir_record, patient, curr_encounter)
              indices[attribute] += 1
              entry = synthea_record.send(attribute)[indices[attribute]]
            end
          end
        end
        fhir_record
      end

      def self.basic_info(entity, fhir_record, end_time = Time.now)
        if entity[:race] == :hispanic
          race_fhir = :other
          ethnicity_fhir = entity[:ethnicity]
        else
          race_fhir = entity[:race]
          ethnicity_fhir = :nonhispanic
        end
        resource_id = SecureRandom.uuid.to_s.strip

        # calls provider to create provider fhir for generalPractitioner in patient_resource
        prov = provider(fhir_record, entity.ambulatory_provider)

        patient_resource = FHIR::DSTU2::Patient.new('id' => resource_id,
                                                    'identifier' => [{
                                                      'system' => 'https://github.com/synthetichealth/synthea',
                                                      'value' => entity.record_synthea.patient_info[:uuid]
                                                    }],
                                                    'name' => [{ 'given' => [entity[:name_first]],
                                                                 'family' => [entity[:name_last]],
                                                                 'use' => 'official' }],
                                                    'telecom' => [{ 'system' => 'phone', 'use' => 'home', 'value' => entity[:telephone] }],
                                                    'gender' => ('male' if entity[:gender] == 'M') || ('female' if entity[:gender] == 'F'),
                                                    'birthDate' => convert_fhir_date_time(entity.event(:birth).time),
                                                    'address' => [FHIR::DSTU2::Address.new(entity[:address])],
                                                    'communication' =>
                                                    {
                                                      'language' => { 'coding' => [LANGUAGE_LOOKUP[entity[:first_language] || :undetermined]] }
                                                    },
                                                    'text' => { 'status' => 'generated',
                                                                'div' => '<div>Generated by <a href="https://github.com/synthetichealth/synthea">Synthea</a>. '\
                                                                          "Version identifier: #{Synthea::Config.version_identifier}</div>" },
                                                    # hospital
                                                    'careProvider' => { 'reference' => prov.fullUrl.to_s },
                                                    'extension' => [
                                                      # race
                                                      {
                                                        'url' => 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-race',
                                                        'valueCodeableConcept' => {
                                                          'text' => 'race',
                                                          'coding' => [{
                                                            'display' => race_fhir.to_s.capitalize,
                                                            'code' => RACE_ETHNICITY_CODES[race_fhir],
                                                            'system' => 'http://hl7.org/fhir/v3/Race'
                                                          }]
                                                        }
                                                      },
                                                      # ethnicity
                                                      {
                                                        'url' => 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity',
                                                        'valueCodeableConcept' => {
                                                          'text' => 'ethnicity',
                                                          'coding' => [{
                                                            'display' => ethnicity_fhir.to_s.capitalize,
                                                            'code' => RACE_ETHNICITY_CODES[ethnicity_fhir],
                                                            'system' => 'http://hl7.org/fhir/v3/Ethnicity'
                                                          }]
                                                        }
                                                      },
                                                      # place of birth
                                                      {
                                                        'url' => 'http://hl7.org/fhir/StructureDefinition/birthPlace',
                                                        'valueAddress' => FHIR::DSTU2::Address.new(entity[:birth_place]).to_hash
                                                      },
                                                      # mother's maiden name
                                                      {
                                                        'url' => 'http://hl7.org/fhir/StructureDefinition/patient-mothersMaidenName',
                                                        'valueString' => entity[:name_mother]
                                                      },
                                                      # birth sex
                                                      {
                                                        'url' => 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-birthsex',
                                                        'valueCode' => entity[:gender]
                                                      },
                                                      {
                                                        'url' => 'http://hl7.org/fhir/StructureDefinition/patient-interpreterRequired',
                                                        'valueBoolean' => false
                                                      }
                                                    ])
        # add optional patient name information
        patient_resource.name.first.prefix << entity[:name_prefix] if entity[:name_prefix]
        patient_resource.name.first.suffix << entity[:name_suffix] if entity[:name_suffix]
        if entity[:name_maiden]
          patient_resource.name << FHIR::DSTU2::HumanName.new('given' => [entity[:name_first]],
                                                              'family' => entity[:name_maiden], 'use' => 'maiden')
        end
        # add geospatial information to address
        patient_resource.address.first.extension = [FHIR::DSTU2::Extension.new('url' => 'http://hl7.org/fhir/StructureDefinition/geolocation',
                                                                               'extension' => [
                                                                                 {
                                                                                   'url' => 'latitude',
                                                                                   'valueDecimal' => entity[:coordinates_address].y
                                                                                 },
                                                                                 {
                                                                                   'url' => 'longitude',
                                                                                   'valueDecimal' => entity[:coordinates_address].x
                                                                                 }
                                                                               ])]
        # add marital status if present
        if entity[:marital_status]
          patient_resource.maritalStatus = FHIR::DSTU2::CodeableConcept.new('coding' => [{ 'system' => 'http://hl7.org/fhir/v3/MaritalStatus', 'code' => entity[:marital_status] }],
                                                                            'text' => entity[:marital_status])
        else
          # single, never married
          patient_resource.maritalStatus = FHIR::DSTU2::CodeableConcept.new('coding' => [{ 'system' => 'http://hl7.org/fhir/v3/MaritalStatus', 'code' => 'S' }],
                                                                            'text' => 'Never Married')
        end
        # add information about twins/triplets if applicable
        if entity[:multiple_birth]
          patient_resource.multipleBirthInteger = entity[:multiple_birth]
        else
          patient_resource.multipleBirthBoolean = false
        end
        # add additional identification numbers if applicable
        if entity[:identifier_ssn]
          patient_resource.identifier << FHIR::DSTU2::Identifier.new('type' => { 'coding' => [{ 'system' => 'http://hl7.org/fhir/identifier-type', 'code' => 'SB' }] },
                                                                     'system' => 'http://hl7.org/fhir/sid/us-ssn', 'value' => entity[:identifier_ssn].delete('-'))
        end
        if entity[:identifier_drivers]
          patient_resource.identifier << FHIR::DSTU2::Identifier.new('type' => { 'coding' => [{ 'system' => 'http://hl7.org/fhir/v2/0203', 'code' => 'DL' }] },
                                                                     'system' => 'urn:oid:2.16.840.1.113883.4.3.25', 'value' => entity[:identifier_drivers])
        end
        if entity[:identifier_passport]
          # system field not strictly required
          patient_resource.identifier << FHIR::DSTU2::Identifier.new('type' => { 'coding' => [{ 'system' => 'http://hl7.org/fhir/v2/0203', 'code' => 'PPN' }] },
                                                                     'value' => entity[:identifier_passport])
        end
        # add medical record number
        if Synthea::Config.exporter.fhir_dstu2.include_mrn
          patient_resource.identifier << FHIR::DSTU2::Identifier.new('type' => { 'coding' => [{ 'system' => 'http://hl7.org/fhir/v2/0203', 'code' => 'MR' }] },
                                                                     'system' => 'http://hospital.smarthealthit.org', 'value' => entity.record_synthea.patient_info[:uuid])
        end
        # add biometric data
        if entity[:fingerprint]
          patient_resource.photo << FHIR::DSTU2::Attachment.new('contentType' => 'image/png', 'title' => 'Biometrics.Fingerprint',
                                                                'data' => Base64.strict_encode64(entity[:fingerprint].to_blob))
        end
        # record death if applicable
        unless entity.alive?(end_time)
          patient_resource.deceasedDateTime = convert_fhir_date_time(entity.record_synthea.patient_info[:deathdate], 'time')
        end

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = patient_resource
        fhir_record.entry << entry
        entry
      end

      def self.condition(condition, fhir_record, patient, encounter)
        resource_id = SecureRandom.uuid
        condition_data = COND_LOOKUP[condition['type']]
        fhir_condition = FHIR::DSTU2::Condition.new('id' => resource_id,
                                                    'patient' => { 'reference' => patient.fullUrl.to_s },
                                                    'code' => {
                                                      'coding' => [{
                                                        'code' => condition_data[:codes]['SNOMED-CT'][0],
                                                        'display' => condition_data[:description],
                                                        'system' => 'http://snomed.info/sct'
                                                      }],
                                                      'text' => condition_data[:description]
                                                    },
                                                    'verificationStatus' => 'confirmed',
                                                    'clinicalStatus' => 'active',
                                                    'onsetDateTime' => convert_fhir_date_time(condition['time'], 'time'),
                                                    'assertedDate' => convert_fhir_date_time(condition['time'], 'date'),
                                                    'encounter' => { 'reference' => encounter.fullUrl.to_s })
        if condition['end_time']
          fhir_condition.abatementDateTime = convert_fhir_date_time(condition['end_time'], 'time')
        end

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = fhir_condition
        fhir_record.entry << entry
      end

      def self.encounter(encounter, fhir_record, patient)
        resource_id = SecureRandom.uuid.to_s
        encounter_data = ENCOUNTER_LOOKUP[encounter['type']]
        reason_data = COND_LOOKUP[encounter['reason']] if encounter['reason']

        end_time = encounter['end_time'] || encounter['time'] + 15.minutes

        provider = nil
        # encounter has an associated provider
        if encounter[:provider]
          provider = provider(fhir_record, encounter[:provider])
        # default provider
        else
          provider = fhir_record.entry.find { |e| e.resource.is_a?(FHIR::DSTU2::Organization) && e.resource.type.coding[0].code == 'prov' }
        end

        fhir_encounter = FHIR::DSTU2::Encounter.new('id' => resource_id,
                                                    'status' => 'finished',
                                                    'class' => encounter_data[:class],
                                                    'type' => [{ 'coding' => [{ 'code' => encounter_data[:codes]['SNOMED-CT'][0], 'system' => 'http://snomed.info/sct' }], 'text' => encounter_data[:description] }],
                                                    'patient' => { 'reference' => patient.fullUrl.to_s },
                                                    'serviceProvider' => { 'reference' => provider.fullUrl.to_s },
                                                    'period' => { 'start' => convert_fhir_date_time(encounter['time'], 'time'), 'end' => convert_fhir_date_time(end_time, 'time') })

        if reason_data
          fhir_encounter.reason = FHIR::DSTU2::CodeableConcept.new('coding' => [{
                                                                     'code' => reason_data[:codes]['SNOMED-CT'][0],
                                                                     'display' => reason_data[:description],
                                                                     'system' => 'http://snomed.info/sct'
                                                                   }])
        end

        if encounter['discharge']
          fhir_encounter.hospitalization = FHIR::DSTU2::Encounter::Hospitalization.new('dischargeDisposition' => {
                                                                                         'coding' => [{
                                                                                           'code' => encounter['discharge'].code,
                                                                                           'display' => encounter['discharge'].display,
                                                                                           'system' => 'http://www.nubc.org/patient-discharge'
                                                                                         }]
                                                                                       })
        end

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = fhir_encounter
        fhir_record.entry << entry
        entry
      end

      def self.provider(fhir_record, provider)
        resource_id = SecureRandom.uuid
        prov = FHIR::DSTU2::Organization.new('id' => resource_id,
                                             'name' => provider.attributes['name'],
                                             'type' => {
                                               'coding' => [{
                                                 'code' => 'prov',
                                                 'display' => 'Healthcare Provider',
                                                 'system' => 'http://hl7.org/fhir/ValueSet/organization-type'
                                               }],
                                               'text' => 'Healthcare Provider'
                                             })

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = prov
        fhir_record.entry << entry
        entry
      end

      def self.allergy(allergy, fhir_record, patient, _encounter)
        snomed_code = COND_LOOKUP[allergy['type']][:codes]['SNOMED-CT'][0]
        allergy = FHIR::DSTU2::AllergyIntolerance.new('recordedDate' => convert_fhir_date_time(allergy['time'], 'time'),
                                                      'status' => allergy['end_time'] ? 'inactive' : 'active',
                                                      'type' => 'allergy',
                                                      'category' => 'food',
                                                      'criticality' => %w(low high).sample,
                                                      'verificationStatus' => 'confirmed',
                                                      'patient' => { 'reference' => patient.fullUrl.to_s },
                                                      'substance' => { 'coding' => [{
                                                        'code' => snomed_code,
                                                        'display' => COND_LOOKUP[allergy['type']][:description],
                                                        'system' => 'http://snomed.info/sct'
                                                      }] })

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.resource = allergy
        fhir_record.entry << entry
      end

      def self.observation(observation, fhir_record, patient, encounter)
        obs_data = OBS_LOOKUP[observation['type']]
        entry = FHIR::DSTU2::Bundle::Entry.new
        resource_id = SecureRandom.uuid
        entry.fullUrl = "urn:uuid:#{resource_id}"
        entry.resource = FHIR::DSTU2::Observation.new('id' => resource_id,
                                                      'status' => 'final',
                                                      'code' => {
                                                        'coding' => [{ 'system' => 'http://loinc.org', 'code' => obs_data[:code], 'display' => obs_data[:description] }],
                                                        'text' => obs_data[:description]
                                                      },
                                                      'category' => {
                                                        'coding' => [{ 'system' => 'http://hl7.org/fhir/observation-category', 'code' => observation['category'] }]
                                                      },
                                                      'subject' => { 'reference' => patient.fullUrl.to_s },
                                                      'encounter' => { 'reference' => encounter.fullUrl.to_s },
                                                      'effectiveDateTime' => convert_fhir_date_time(observation['time'], 'time'),
                                                      'issued' => convert_fhir_date_time(observation['time'], 'time'))

        if obs_data[:value_type] == 'condition'
          condition_data = COND_LOOKUP[observation['value']]
          entry.resource.valueCodeableConcept = FHIR::DSTU2::CodeableConcept.new('coding' => [{
                                                                                   'code' => condition_data[:codes]['SNOMED-CT'][0],
                                                                                   'display' => condition_data[:description],
                                                                                   'system' => 'http://snomed.info/sct'
                                                                                 }],
                                                                                 'text' => condition_data[:description])
        elsif observation['value'].to_s =~ /\A[-+]?\d*\.?\d+\z/
          entry.resource.valueQuantity = FHIR::DSTU2::Quantity.new('value' => observation['value'], 'unit' => obs_data[:unit], 'code' => obs_data[:unit], 'system' => 'http://unitsofmeasure.org/')
        else
          entry.resource.valueString = observation['value']
        end

        fhir_record.entry << entry
      end

      def self.multi_observation(multi_obs, fhir_record, patient, encounter)
        entry = FHIR::DSTU2::Bundle::Entry.new
        resource_id = SecureRandom.uuid
        entry.fullUrl = "urn:uuid:#{resource_id}"
        observations = fhir_record.entry.pop(multi_obs['value'])
        multi_data = OBS_LOOKUP[multi_obs['type']]
        fhir_observation = FHIR::DSTU2::Observation.new('id' => resource_id,
                                                        'status' => 'final',
                                                        'code' => {
                                                          'coding' => [{ 'system' => 'http://loinc.org', 'code' => multi_data[:code], 'display' => multi_data[:description] }]
                                                        },
                                                        'category' => {
                                                          'coding' => [{ 'system' => 'http://hl7.org/fhir/observation-category', 'code' => multi_obs['category'] }]
                                                        },
                                                        'subject' => { 'reference' => patient.fullUrl.to_s },
                                                        'encounter' => { 'reference' => encounter.fullUrl.to_s },
                                                        'effectiveDateTime' => convert_fhir_date_time(multi_obs['time'], 'time'),
                                                        'issued' => convert_fhir_date_time(multi_obs['time'], 'time'))
        observations.each do |obs|
          fhir_observation.component << FHIR::DSTU2::Observation::Component.new('code' => obs.resource.code.to_hash, 'valueQuantity' => obs.resource.valueQuantity.to_hash)
        end

        entry.resource = fhir_observation
        fhir_record.entry << entry
      end

      def self.diagnostic_report(report, fhir_record, patient, encounter)
        entry = FHIR::DSTU2::Bundle::Entry.new
        resource_id = SecureRandom.uuid
        entry.fullUrl = "urn:uuid:#{resource_id}"
        report_data = OBS_LOOKUP[report['type']]
        entry.resource = FHIR::DSTU2::DiagnosticReport.new('id' => resource_id,
                                                           'status' => 'final',
                                                           'code' => {
                                                             'coding' => [{ 'system' => 'http://loinc.org', 'code' => report_data[:code], 'display' => report_data[:description] }]
                                                           },
                                                           'subject' => { 'reference' => patient.fullUrl.to_s },
                                                           'encounter' => { 'reference' => encounter.fullUrl.to_s },
                                                           'effectiveDateTime' => convert_fhir_date_time(report['time'], 'time'),
                                                           'issued' => convert_fhir_date_time(report['time'], 'time'))
        entry.resource.result = []
        obs_entries = fhir_record.entry.last(report['numObs'])
        obs_entries.each do |e|
          entry.resource.result << FHIR::DSTU2::Reference.new('reference' => e.fullUrl.to_s, 'display' => e.resource.code.coding.first.display)
        end

        fhir_record.entry << entry
      end

      def self.procedure(procedure, fhir_record, patient, encounter)
        if procedure['reason']
          reason_code = COND_LOOKUP[procedure['reason']][:codes]['SNOMED-CT'][0]
          reason = fhir_record.entry.find { |e| e.resource.is_a?(FHIR::DSTU2::Condition) && e.resource.code.coding.find { |c| c.code == reason_code } }
        end
        proc_data = PROCEDURE_LOOKUP[procedure['type']]
        fhir_procedure = FHIR::DSTU2::Procedure.new('subject' => { 'reference' => patient.fullUrl.to_s },
                                                    'status' => 'completed',
                                                    'code' => {
                                                      'coding' => [{ 'code' => proc_data[:codes]['SNOMED-CT'][0], 'display' => proc_data[:description], 'system' => 'http://snomed.info/sct' }],
                                                      'text' => proc_data[:description]
                                                    },
                                                    # 'reasonReference' => { 'reference' => reason.resource.id },
                                                    # 'performer' => { 'reference' => doctor_no_good },
                                                    'encounter' => { 'reference' => encounter.fullUrl.to_s })
        fhir_procedure.reasonReference = FHIR::DSTU2::Reference.new('reference' => reason.fullUrl.to_s, 'display' => reason.resource.code.text) if reason

        start_time = convert_fhir_date_time(procedure['time'], 'time')
        if procedure['duration']
          end_time = convert_fhir_date_time(procedure['time'] + procedure['duration'], 'time')
          fhir_procedure.performedPeriod = FHIR::DSTU2::Period.new('start' => start_time, 'end' => end_time)
        else
          fhir_procedure.performedDateTime = start_time
        end

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.resource = fhir_procedure
        fhir_record.entry << entry
      end

      def self.immunization(imm, fhir_record, patient, encounter)
        immunization = FHIR::DSTU2::Immunization.new('status' => 'completed',
                                                     'date' => convert_fhir_date_time(imm['time'], 'time'),
                                                     'vaccineCode' => {
                                                       'coding' => [IMM_SCHEDULE[imm['type']][:code]],
                                                       'text' => IMM_SCHEDULE[imm['type']][:code]['display']
                                                     },
                                                     'patient' => { 'reference' => patient.fullUrl.to_s },
                                                     'wasNotGiven' => false,
                                                     'encounter' => { 'reference' => encounter.fullUrl.to_s })

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.resource = immunization
        fhir_record.entry << entry
      end

      def self.careplans(plan, fhir_record, patient, encounter)
        careplan_data = CAREPLAN_LOOKUP[plan['type']]
        reasons = []
        plan['reasons'].each do |reason|
          reason_code = COND_LOOKUP[reason][:codes]['SNOMED-CT'][0]
          r = fhir_record.entry.find { |e| e.resource.is_a?(FHIR::DSTU2::Condition) && reason_code == e.resource.code.coding[0].code }
          reasons << r unless r.nil?
        end

        careplan = FHIR::DSTU2::CarePlan.new('subject' => { 'reference' => patient.fullUrl.to_s },
                                             'context' => { 'reference' => encounter.fullUrl.to_s },
                                             'period' => { 'start' => convert_fhir_date_time(plan['start_time']) },
                                             'category' => [{
                                               'coding' => [{
                                                 'code' => careplan_data[:codes]['SNOMED-CT'][0],
                                                 'display' => careplan_data[:description],
                                                 'system' => 'http://snomed.info/sct'
                                               }]
                                             }],
                                             'activity' => [],
                                             'goal' => [],
                                             'addresses' => [])
        reasons.each do |r|
          careplan.addresses << FHIR::DSTU2::Reference.new('reference' => r.fullUrl.to_s) unless reasons.nil? || reasons.empty?
        end
        if plan['stop']
          careplan.period.end = convert_fhir_date_time(plan['stop'])
          careplan.status = 'completed'
          activity_status = 'completed'
          goal_status = 'achieved'
        else
          careplan.status = 'active'
          activity_status = 'in-progress'
          goal_status = 'in-progress'
        end
        plan['activities'].each do |activity|
          activity_data = CAREPLAN_LOOKUP[activity]
          careplan.activity << FHIR::DSTU2::CarePlan::Activity.new('detail' => {
                                                                     'status' => activity_status,
                                                                     'code' => {
                                                                       'coding' => [{
                                                                         'code' => activity_data[:codes]['SNOMED-CT'][0],
                                                                         'display' => activity_data[:description],
                                                                         'system' => 'http://snomed.info/sct'
                                                                       }]
                                                                     }
                                                                   })
        end

        plan['goals'].each do |goal|
          fhir_goal = care_goal(goal, goal_status, fhir_record)

          careplan.goal << FHIR::DSTU2::Reference.new('reference' => fhir_goal.fullUrl.to_s)
        end

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.resource = careplan
        fhir_record.entry << entry
      end

      def self.care_goal(goal, goal_status, fhir_record)
        # TODO: search the patient for existing & acive matching goals
        # instead of always creating new ones?
        fhir_goal = FHIR::DSTU2::Goal.new('status' => goal_status)

        # goal has :observation, :text, :addresses, :codes

        fhir_goal.description =
          if goal[:text]
            FHIR::DSTU2::CodeableConcept.new('text' => goal[:text])
          elsif goal[:codes]
            code = goal[:codes][0]
            FHIR::DSTU2::CodeableConcept.new('coding' => [{ 'system' => 'http://loinc.org', 'code' => code.code, 'display' => code.display }],
                                             'text' => code.display)
          elsif goal[:observation]
            # build up our own text from the observation condition, similar to the graphviz logic
            logic = goal[:observation]
            text = "#{logic.codes[0].display} #{logic.operator} #{logic.value}"

            # don't use the code here because the code by itself doesn't specify the goal,
            # it specifies the attribute on which a goal has been set
            FHIR::DSTU2::CodeableConcept.new('text' => text)
          end

        reasons = []
        (goal[:addresses] || []).each do |reason|
          reason_code = COND_LOOKUP[reason][:codes]['SNOMED-CT'][0]
          r = fhir_record.entry.find { |e| e.resource.is_a?(FHIR::DSTU2::Condition) && reason_code == e.resource.code.coding[0].code }
          reasons << r unless r.nil?
        end

        reasons.each do |r|
          fhir_goal.addresses << FHIR::DSTU2::Reference.new('reference' => r.fullUrl.to_s) unless reasons.nil? || reasons.empty?
        end

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.resource = fhir_goal
        fhir_record.entry << entry
        entry
      end

      def self.medications(prescription, fhir_record, patient, encounter)
        med_data = MEDICATION_LOOKUP[prescription['type']]
        reasons = []
        prescription['reasons'].each do |reason|
          reason_code = COND_LOOKUP[reason][:codes]['SNOMED-CT'][0]
          r = fhir_record.entry.find { |e| e.resource.is_a?(FHIR::DSTU2::Condition) && reason_code == e.resource.code.coding[0].code }
          reasons << r unless r.nil?
        end

        # Additional dosage information, if available
        dosage_instruction = {}
        dispense_request = {}

        unless prescription['rx_info'].empty?
          rx_info = prescription['rx_info']
          dosage_instruction = {
            'asNeededBoolean' => rx_info['as_needed']
          }

          unless rx_info['as_needed']
            # Timing of each dose
            dosage_instruction['timing'] = {
              'repeat' => {
                'frequency' => rx_info['dosage'].frequency,
                'period' => rx_info['dosage'].period,
                'periodUnits' => convert_ucum_code(rx_info['dosage'].unit)
              }
            }
            # Amount of each dose
            dosage_instruction['doseQuantity'] = {
              'value' => rx_info['dosage'].amount
            }
            # Additional instructions
            dosage_instruction['additionalInstructions'] = []
            unless rx_info['instructions'].nil?
              rx_info['instructions'].each do |sym|
                instr = INSTRUCTION_LOOKUP[sym]
                dosage_instruction['additionalInstructions'] << {
                  'coding' => [{
                    'code' => instr[:codes]['SNOMED-CT'][0],
                    'display' => instr[:description],
                    'system' => 'http://snomed.info/sct'
                  }]
                }
              end
            end
            # Prescription information
            dispense_request = {
              'numberOfRepeatsAllowed' => rx_info['refills'],
              'quantity' => {
                'value' => rx_info['total_doses'],
                'unit' => 'doses'
              },
              'expectedSupplyDuration' => {
                'value' => rx_info['duration'].quantity,
                'unit' => rx_info['duration'].unit,
                'system' => 'http://hl7.org/fhir/ValueSet/units-of-time',
                'code' => convert_ucum_code(rx_info['duration'].unit)
              }
            }
          end
        end

        med_order = FHIR::DSTU2::MedicationOrder.new('medicationCodeableConcept' => {
                                                       'coding' => [{
                                                         'code' => med_data[:codes]['RxNorm'][0],
                                                         'display' => med_data[:description],
                                                         'system' => 'http://www.nlm.nih.gov/research/umls/rxnorm'
                                                       }],
                                                       'text' => med_data[:description]
                                                     },
                                                     'stage' => {
                                                       'coding' => {
                                                         'code' => 'original-order',
                                                         'system' => 'http://hl7.org/fhir/request-stage'
                                                       }
                                                     },
                                                     'patient' => { 'reference' => patient.fullUrl.to_s },
                                                     'encounter' => { 'reference' => encounter.fullUrl.to_s },
                                                     'dateWritten' => convert_fhir_date_time(prescription['start_time']),
                                                     'reasonReference' => [],
                                                     'dosageInstruction' => [dosage_instruction],
                                                     'dispenseRequest' => dispense_request)
        reasons.each do |r|
          med_order.reasonReference << FHIR::DSTU2::Reference.new('reference' => r.fullUrl.to_s)
        end

        med_order.status = if prescription['stop']
                             'stopped'
                           else
                             'active'
                           end

        entry = FHIR::DSTU2::Bundle::Entry.new
        entry.resource = med_order
        fhir_record.entry << entry
      end

      def self.convert_fhir_date_time(date, option = nil)
        date = Time.at(date) if date.is_a?(Integer)
        if option == 'time'
          x = date.to_s.sub(' ', 'T')
          x = x.sub(' ', '')
          x = x.insert(-3, ':')
          return Regexp.new(FHIR::DSTU2::PRIMITIVES['dateTime']['regex']).match(x.to_s).to_s
        else
          return Regexp.new(FHIR::DSTU2::PRIMITIVES['date']['regex']).match(date.to_s).to_s
        end
      end

      # From: http://hl7.org/fhir/ValueSet/units-of-time
      def self.convert_ucum_code(unit)
        case unit
        when 'seconds'
          return 's'
        when 'minutes'
          return 'min'
        when 'hours'
          return 'h'
        when 'days'
          return 'd'
        when 'weeks'
          return 'wk'
        when 'months'
          return 'mo'
        when 'years'
          return 'a'
        end
        raise "#{unit} is not a recognized unit of time"
      end
    end
  end
end
