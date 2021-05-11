package org.mitre.synthea.modules;

import org.apache.commons.lang3.tuple.ImmutableTriple;
import org.apache.commons.lang3.tuple.Triple;
import org.hl7.fhir.utilities.CSVReader;
import org.mitre.synthea.helpers.Config;
import org.mitre.synthea.helpers.SimpleCSV;
import org.mitre.synthea.world.agents.Person;
import org.mitre.synthea.world.concepts.HealthRecord;
import org.mitre.synthea.world.concepts.HealthRecord.Observation;
import org.springframework.util.StringUtils;

import java.io.File;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.LinkedHashMap;
import java.util.LinkedList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

public class AutoObservationGenerator {
    private static String fixedDataPath = "C:\\Users\\tongwu\\Downloads\\demo\\demo\\gen\\samples";

    private static String[] sampleFiles = null;
    private static String[] getSampleFiles() {
        if (sampleFiles == null) {
            sampleFiles = (new File(fixedDataPath)).list();
        }

        return sampleFiles;
    }

    public static List<Observation> generateObservations(HealthRecord record, long time, int seed) throws IOException {
        List<Observation> result = new LinkedList<>();
        String[] sampleFiles = getSampleFiles();

        String observationsFile = sampleFiles[seed % sampleFiles.length];
        String inputDataString = readFile(Paths.get(fixedDataPath, observationsFile).toString(), StandardCharsets.UTF_8);
        List<LinkedHashMap<String, String>> inputData = SimpleCSV.parse(inputDataString);

        for (LinkedHashMap<String, String> input : inputData) {
            long seconds = (long)(Float.parseFloat(input.get("Hours")) * 60 * 60);
            long startTime = TimeUnit.SECONDS.toMillis(seconds) + time;
            Observation newObservation = record.createEmptyObservation(time, startTime, null, null);

            Observation properties = getDiastolicBloodPresure(record, time, startTime, input);
            if (properties != null) {
                newObservation.observations.add(properties);
            }

            properties = getSystolicBloodPresure(record, time, startTime, input);
            if (properties != null) {
                newObservation.observations.add(properties);
            }

            result.add(newObservation);
        }
        return result;
    }

    private static Observation getDiastolicBloodPresure (HealthRecord record, long time, long startTime, LinkedHashMap<String, String> input) {
        if (!input.containsKey("Diastolic blood pressure")) {
            return null;
        }

        String content = input.get("Diastolic blood pressure");

        if (StringUtils.isEmpty(content)) {
            return null;
        }

        Observation observation = record.createEmptyObservation(time, startTime, null, null);
        float bloodPressure = Float.parseFloat(content);

        observation.value = bloodPressure;
        observation.unit = "mmHg";
        observation.codes.add(new HealthRecord.Code("http://loinc.org", "8462-4", "Diastolic blood pressure"));

        return observation;
    }

    private static Observation getSystolicBloodPresure (HealthRecord record, long time, long startTime, LinkedHashMap<String, String> input) {
        if (!input.containsKey("Systolic blood pressure")) {
            return null;
        }

        String content = input.get("Systolic blood pressure");

        if (StringUtils.isEmpty(content)) {
            return null;
        }

        Observation observation = record.createEmptyObservation(time, startTime, null, null);
        float bloodPressure = Float.parseFloat(content);

        observation.value = bloodPressure;
        observation.unit = "mmHg";
        observation.codes.add(new HealthRecord.Code("http://loinc.org", "8480-6", "Systolic blood pressure"));

        return observation;
    }

    private static String readFile(String path, Charset encoding) throws IOException {
        String content = Files.lines(Paths.get(path), encoding)
                .collect(Collectors.joining(System.lineSeparator()));

        return content;
    }

    public static void main(String args[]) {
        HealthRecord record = new HealthRecord(new Person(1000));
        try {
            generateObservations(record, 0, 11);
        }
        catch (IOException ioEx) {

        }
    }
}
